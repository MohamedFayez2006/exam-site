-- نفّذ الملف كله مرة واحدة في Supabase → SQL Editor
alter table exams add column if not exists instructions text,
  add column if not exists shuffle boolean not null default true,
  add column if not exists show_results boolean not null default false;
alter table profiles add column if not exists is_active boolean not null default true;
alter table attempts add column if not exists expires_at timestamptz,
  add column if not exists violation_count int not null default 0,
  add column if not exists last_seen timestamptz,
  add column if not exists device_token text,
  add column if not exists auto_score numeric,
  add column if not exists locked_reason text;

drop policy if exists "violations student insert" on violations;
drop policy if exists "answers student" on answers;
create policy "answers student read" on answers for select
  using (exists (select 1 from attempts a where a.id = answers.attempt_id and a.student_id = auth.uid()));
drop function if exists start_attempt(uuid);

create or replace function _finalize(p_attempt uuid, p_status text, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_auto numeric;
begin
  select coalesce(sum(q.points),0) into v_auto
  from answers an join questions q on q.id = an.question_id
  join answer_keys k on k.question_id = q.id
  where an.attempt_id = p_attempt and an.answer = k.correct_answer;
  update attempts set status = p_status, submitted_at = least(now(), expires_at), auto_score = v_auto,
    score = v_auto + coalesce((select sum(manual_grade) from answers where attempt_id = p_attempt),0),
    locked_reason = p_reason
  where id = p_attempt and status = 'in_progress';
end $$;
revoke execute on function _finalize(uuid,text,text) from public, anon, authenticated;

create or replace function start_attempt(p_exam_id uuid, p_device text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_exam exams%rowtype; v_count int; v_att attempts%rowtype; v_appr uuid; v_new uuid;
begin
  if not exists (select 1 from profiles where id = auth.uid() and is_active and role = 'student') then
    raise exception 'not_allowed'; end if;
  select * into v_exam from exams where id = p_exam_id and is_published;
  if not found then raise exception 'exam_not_available'; end if;
  select * into v_att from attempts where student_id = auth.uid() and exam_id = p_exam_id and status = 'in_progress';
  if found then
    if v_att.expires_at <= now() then perform _finalize(v_att.id, 'submitted'); raise exception 'time_over'; end if;
    update attempts set device_token = p_device, last_seen = now() where id = v_att.id;
    return v_att.id;
  end if;
  if (v_exam.opens_at is not null and now() < v_exam.opens_at)
     or (v_exam.closes_at is not null and now() > v_exam.closes_at) then raise exception 'exam_closed'; end if;
  select count(*) into v_count from attempts where student_id = auth.uid() and exam_id = p_exam_id;
  if v_count > 0 then
    select id into v_appr from retake_approvals
      where student_id = auth.uid() and exam_id = p_exam_id and not used order by approved_at limit 1 for update;
    if not found then raise exception 'no_attempts_left'; end if;
    update retake_approvals set used = true where id = v_appr;
  end if;
  insert into attempts (student_id, exam_id, attempt_number, expires_at, device_token, last_seen)
  values (auth.uid(), p_exam_id, v_count + 1, now() + make_interval(mins => v_exam.duration_minutes), p_device, now())
  returning id into v_new;
  return v_new;
end $$;

create or replace function heartbeat(p_attempt uuid, p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype; mx int;
begin
  select * into a from attempts where id = p_attempt and student_id = auth.uid();
  if not found then raise exception 'not_found'; end if;
  if a.status = 'in_progress' and a.expires_at <= now() then
    perform _finalize(a.id, 'submitted'); select * into a from attempts where id = a.id; end if;
  if a.status = 'in_progress' and a.device_token is distinct from p_device then raise exception 'other_device'; end if;
  if a.status = 'in_progress' then update attempts set last_seen = now() where id = a.id; end if;
  select max_violations into mx from exams where id = a.exam_id;
  return jsonb_build_object('status', a.status,
    'remaining', greatest(0, extract(epoch from (a.expires_at - now()))::int),
    'violations', a.violation_count, 'max', mx);
end $$;

create or replace function save_answer(p_attempt uuid, p_question uuid, p_answer text, p_device text)
returns void language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype;
begin
  select * into a from attempts where id = p_attempt and student_id = auth.uid() and status = 'in_progress';
  if not found then raise exception 'not_active'; end if;
  if a.device_token is distinct from p_device then raise exception 'other_device'; end if;
  if now() > a.expires_at + interval '5 seconds' then raise exception 'time_over'; end if;
  if not exists (select 1 from questions where id = p_question and exam_id = a.exam_id) then
    raise exception 'bad_question'; end if;
  insert into answers (attempt_id, question_id, answer) values (p_attempt, p_question, left(p_answer, 20000))
  on conflict (attempt_id, question_id) do update set answer = excluded.answer;
end $$;

create or replace function log_violation(p_attempt uuid, p_type text, p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype; mx int; n int;
begin
  select * into a from attempts where id = p_attempt and student_id = auth.uid() and status = 'in_progress';
  if not found then return jsonb_build_object('locked', true); end if;
  if a.device_token is distinct from p_device then raise exception 'other_device'; end if;
  select max_violations into mx from exams where id = a.exam_id;
  insert into violations (attempt_id, type) values (p_attempt, left(p_type, 40));
  update attempts set violation_count = violation_count + 1 where id = p_attempt returning violation_count into n;
  if n >= mx then perform _finalize(p_attempt, 'locked', 'violations'); end if;
  return jsonb_build_object('count', n, 'max', mx, 'locked', n >= mx);
end $$;

create or replace function submit_attempt(p_attempt uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from attempts where id = p_attempt and student_id = auth.uid()) then
    raise exception 'not_found'; end if;
  perform _finalize(p_attempt, 'submitted');
end $$;

create or replace function grade_essay(p_answer uuid, p_grade numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_att uuid;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  update answers set manual_grade = p_grade where id = p_answer returning attempt_id into v_att;
  update attempts set score = coalesce(auto_score,0) + coalesce((select sum(manual_grade) from answers where attempt_id = v_att),0)
  where id = v_att and status <> 'in_progress';
end $$;

create or replace function finalize_expired()
returns void language plpgsql security definer set search_path = public as $$
declare r uuid;
begin
  for r in select id from attempts where status = 'in_progress' and expires_at < now() - interval '10 seconds'
  loop perform _finalize(r, 'submitted'); end loop;
end $$;

revoke execute on function start_attempt(uuid,text), heartbeat(uuid,text), save_answer(uuid,uuid,text,text),
  log_violation(uuid,text,text), submit_attempt(uuid), grade_essay(uuid,numeric), finalize_expired() from public, anon;
grant execute on function start_attempt(uuid,text), heartbeat(uuid,text), save_answer(uuid,uuid,text,text),
  log_violation(uuid,text,text), submit_attempt(uuid), grade_essay(uuid,numeric), finalize_expired() to authenticated;
