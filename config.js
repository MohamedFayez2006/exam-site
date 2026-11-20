// حط هنا بيانات مشروع Supabase (Project Settings → API)
// المفتاح المسموح هنا هو anon / publishable فقط. ممنوع service_role نهائيًا.
const SUPABASE_URL = "https://supabase.com/dashboard/project/lrbwxtizymxlstnkjlsm";
const SUPABASE_ANON_KEY = "sb_publishable_piCSaQCkZR5Eq2ru6gdlTQ_fSzuYB5r";
const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// لازم يطابقوا القيم الموجودة في دالة add-student
const PASSWORD_PREFIX = "ex-";
const EMAIL_DOMAIN = "students.example.com";
