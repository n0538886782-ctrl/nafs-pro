-- =====================================================================
--  منصة تدريب نافس - الخطوة 1: الجداول + الأمان + الدوال
--  شغّل الملف كاملاً مرة واحدة من: Supabase > SQL Editor > New query
--  المراحل: p6 = سادس ابتدائي (فصول 1-5) ، m3 = ثالث متوسط (فصول 1-4)
--  المواد: math = رياضيات ، arabic = لغتي ، science = علوم
-- =====================================================================

-- ---------- 1) الجداول ----------

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  national_id text unique,
  grade text check (grade in ('p6','m3')),
  class_no smallint,
  role text not null default 'student' check (role in ('student','admin')),
  is_active boolean not null default true,
  must_change_password boolean not null default false,
  created_at timestamptz not null default now(),
  last_login timestamptz,
  constraint class_valid check (
    role = 'admin'
    or (grade = 'p6' and class_no between 1 and 5)
    or (grade = 'm3' and class_no between 1 and 4))
);

-- قائمة الطلاب المعتمدين (يرفعها المدير من Excel/Word)
create table public.allowed_students (
  national_id text primary key check (national_id ~ '^[0-9]{10}$'),
  full_name text not null,
  grade text not null check (grade in ('p6','m3')),
  class_no smallint not null,
  registered boolean not null default false,
  created_at timestamptz not null default now(),
  constraint allowed_class_valid check (
    (grade = 'p6' and class_no between 1 and 5)
    or (grade = 'm3' and class_no between 1 and 4))
);

create table public.settings (
  key text primary key,
  value jsonb not null
);
insert into public.settings(key, value) values
  ('duration_min', '45'),              -- مدة الاختبار بالدقائق
  ('questions_per_quiz', '10'),        -- عدد الأسئلة
  ('max_attempts_per_week', '0'),      -- 0 = بلا حد
  ('require_allowed_list', 'true'),    -- التسجيل لمن في القائمة فقط
  ('grace_seconds', '5');              -- سماح بسيط لتأخر الشبكة

create table public.questions (
  id uuid primary key default gen_random_uuid(),
  grade text not null check (grade in ('p6','m3')),
  subject text not null check (subject in ('math','arabic','science')),
  skill text,                                   -- المهارة (الكسور، الاستيعاب...)
  text text not null,
  image_url text,
  options jsonb not null check (jsonb_typeof(options) = 'array'
                                and jsonb_array_length(options) between 2 and 6),
  difficulty smallint default 2 check (difficulty between 1 and 3),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index on public.questions(grade, subject) where active;

-- الإجابات الصحيحة منفصلة، ولا يقرؤها إلا المدير
create table public.answer_key (
  question_id uuid primary key references public.questions(id) on delete cascade,
  correct_option smallint not null,             -- رقم الخيار الصحيح يبدأ من 0
  explanation text
);

create table public.attempts (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.profiles(id) on delete cascade,
  grade text not null,
  subject text not null,
  started_at timestamptz not null default now(),
  deadline_at timestamptz not null,
  finished_at timestamptz,
  status text not null default 'in_progress' check (status in ('in_progress','finished')),
  score int,
  total int not null,
  tab_leaves int not null default 0
);
create index on public.attempts(student_id, subject, started_at desc);

create table public.attempt_questions (
  attempt_id uuid references public.attempts(id) on delete cascade,
  question_id uuid references public.questions(id) on delete cascade,
  position int not null,
  option_order int[] not null,                  -- ترتيب الخيارات العشوائي لهذا الطالب
  primary key (attempt_id, question_id)
);

create table public.responses (
  attempt_id uuid references public.attempts(id) on delete cascade,
  question_id uuid references public.questions(id) on delete cascade,
  chosen smallint,
  is_correct boolean,                           -- يبقى فارغاً حتى التسليم
  answered_at timestamptz not null default now(),
  primary key (attempt_id, question_id)
);

-- ---------- 2) دوال مساعدة ----------

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from profiles
                where id = auth.uid() and role = 'admin' and is_active)
$$;

create or replace function public.setting_int(k text, d int) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select (value #>> '{}')::int from settings where key = k), d)
$$;

-- ---------- 3) إنشاء الملف الشخصي عند التسجيل ----------
-- الطالب يسجّل بالبريد الداخلي: رقم_الهوية@nafes.local
-- أي حساب بريده غير ذلك لا يحصل على ملف شخصي (فلا يرى شيئاً)

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  nid text; meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  a allowed_students%rowtype; v_grade text; v_class smallint; v_name text; need boolean;
begin
  if new.email is null or new.email not like '%@nafes.local' then
    return new;
  end if;
  nid := split_part(new.email, '@', 1);
  if nid !~ '^[0-9]{10}$' then
    raise exception 'رقم الهوية يجب أن يكون 10 أرقام';
  end if;

  select (value #>> '{}')::boolean into need from settings where key = 'require_allowed_list';
  select * into a from allowed_students where national_id = nid;

  if found then
    v_grade := a.grade; v_class := a.class_no; v_name := a.full_name;
  else
    if coalesce(need, true) then
      raise exception 'رقم الهوية غير مسجل لدى المدير';
    end if;
    v_grade := meta->>'grade';
    v_class := nullif(meta->>'class_no', '')::smallint;
    v_name  := nullif(trim(meta->>'full_name'), '');
  end if;
  if v_name is null or v_grade is null or v_class is null then
    raise exception 'بيانات التسجيل ناقصة';
  end if;

  insert into profiles(id, full_name, national_id, grade, class_no)
  values (new.id, v_name, nid, v_grade, v_class);
  update allowed_students set registered = true where national_id = nid;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 4) سياسات الأمان RLS ----------

alter table public.profiles          enable row level security;
alter table public.allowed_students  enable row level security;
alter table public.settings          enable row level security;
alter table public.questions         enable row level security;
alter table public.answer_key        enable row level security;
alter table public.attempts          enable row level security;
alter table public.attempt_questions enable row level security;
alter table public.responses         enable row level security;

-- الطالب يقرأ ملفه فقط، والمدير يدير الجميع
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.is_admin());
create policy profiles_admin_write on public.profiles for all
  using (public.is_admin()) with check (public.is_admin());

create policy allowed_admin on public.allowed_students for all
  using (public.is_admin()) with check (public.is_admin());

create policy settings_read on public.settings for select to authenticated using (true);
create policy settings_admin on public.settings for all
  using (public.is_admin()) with check (public.is_admin());

-- بنك الأسئلة والإجابات: للمدير فقط (الطالب يستلم أسئلته عبر الدوال)
create policy questions_admin on public.questions for all
  using (public.is_admin()) with check (public.is_admin());
create policy answer_key_admin on public.answer_key for all
  using (public.is_admin()) with check (public.is_admin());

-- المحاولات والإجابات: قراءة فقط للطالب (الكتابة عبر الدوال)
create policy attempts_select on public.attempts for select
  using (student_id = auth.uid() or public.is_admin());
create policy aq_select on public.attempt_questions for select
  using (public.is_admin() or exists (
    select 1 from attempts a where a.id = attempt_id and a.student_id = auth.uid()));
create policy responses_select on public.responses for select
  using (public.is_admin() or exists (
    select 1 from attempts a where a.id = attempt_id and a.student_id = auth.uid()));

-- ---------- 5) دوال الاختبار (تعمل على الخادم) ----------

-- تصحيح محاولة وإغلاقها نهائياً (داخلية)
create or replace function public.grade_attempt(p_attempt uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype;
begin
  select * into a from attempts where id = p_attempt for update;
  if not found or a.finished_at is not null then return; end if;

  insert into responses(attempt_id, question_id, chosen, is_correct)
  select aq.attempt_id, aq.question_id, null, false
  from attempt_questions aq where aq.attempt_id = p_attempt
  on conflict (attempt_id, question_id) do nothing;

  update responses r
     set is_correct = (r.chosen is not null and r.chosen = k.correct_option)
    from answer_key k
   where r.attempt_id = p_attempt and k.question_id = r.question_id;

  update attempts
     set finished_at = now(), status = 'finished',
         score = (select count(*) from responses
                  where attempt_id = p_attempt and is_correct)
   where id = p_attempt;
end $$;

-- إغلاق المحاولات المنتهية وقتها (داخلية)
create or replace function public.finalize_expired(p_student uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from attempts
           where student_id = p_student and finished_at is null
             and now() > deadline_at + make_interval(secs => setting_int('grace_seconds', 5))
  loop
    perform grade_attempt(r.id);
  end loop;
end $$;

-- بدء اختبار في مادة (أو متابعة اختبار مفتوح)
create or replace function public.start_attempt(p_subject text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me profiles%rowtype; v_id uuid; n int; dur int; maxw int; cnt int;
begin
  select * into me from profiles where id = auth.uid();
  if not found or me.role <> 'student' or not me.is_active then
    raise exception 'غير مصرح';
  end if;
  if p_subject not in ('math','arabic','science') then
    raise exception 'مادة غير صحيحة';
  end if;

  perform finalize_expired(me.id);

  select id into v_id from attempts
   where student_id = me.id and subject = p_subject and finished_at is null limit 1;
  if v_id is not null then return v_id; end if;

  maxw := setting_int('max_attempts_per_week', 0);
  if maxw > 0 then
    select count(*) into cnt from attempts
     where student_id = me.id and subject = p_subject
       and started_at > now() - interval '7 days';
    if cnt >= maxw then raise exception 'استنفدت محاولاتك لهذا الأسبوع'; end if;
  end if;

  n   := setting_int('questions_per_quiz', 10);
  dur := setting_int('duration_min', 45);

  insert into attempts(student_id, grade, subject, deadline_at, total)
  values (me.id, me.grade, p_subject, now() + make_interval(mins => dur), n)
  returning id into v_id;

  -- أسئلة عشوائية، مع تفضيل ما لم يحلّه الطالب سابقاً
  with picked as (
    select qu.id, qu.options,
           exists (select 1 from attempt_questions aq
                   join attempts at2 on at2.id = aq.attempt_id
                   where at2.student_id = me.id and aq.question_id = qu.id) as seen
      from questions qu
     where qu.grade = me.grade and qu.subject = p_subject and qu.active
     order by seen, random()
     limit n
  )
  insert into attempt_questions(attempt_id, question_id, position, option_order)
  select v_id, id, row_number() over (order by random()),
         (select array_agg(i - 1 order by random())
            from generate_series(1, jsonb_array_length(options)) i)
    from picked;

  select count(*) into cnt from attempt_questions where attempt_id = v_id;
  if cnt = 0 then raise exception 'لا توجد أسئلة متاحة لهذه المادة حالياً'; end if;
  update attempts set total = cnt where id = v_id;

  return v_id;
end $$;

-- جلب المحاولة الجارية (الأسئلة بدون إجابات) مع وقت الخادم
create or replace function public.get_attempt(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype;
begin
  select * into a from attempts where id = p_attempt and student_id = auth.uid();
  if not found then raise exception 'المحاولة غير موجودة'; end if;

  if a.finished_at is null
     and now() > a.deadline_at + make_interval(secs => setting_int('grace_seconds', 5)) then
    perform grade_attempt(a.id);
    select * into a from attempts where id = p_attempt;
  end if;

  return jsonb_build_object(
    'attempt', jsonb_build_object('id', a.id, 'subject', a.subject, 'grade', a.grade,
               'started_at', a.started_at, 'deadline_at', a.deadline_at,
               'finished_at', a.finished_at, 'total', a.total),
    'server_now', now(),
    'questions', case when a.finished_at is not null then '[]'::jsonb else (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', q.id, 'position', aq.position, 'text', q.text,
        'image_url', q.image_url, 'skill', q.skill,
        'options', (select jsonb_agg(jsonb_build_object('idx', o, 'text', q.options ->> o) order by ord)
                      from unnest(aq.option_order) with ordinality as t(o, ord))
      ) order by aq.position), '[]'::jsonb)
      from attempt_questions aq join questions q on q.id = aq.question_id
      where aq.attempt_id = a.id) end,
    'saved', (select coalesce(jsonb_object_agg(question_id, chosen), '{}'::jsonb)
                from responses where attempt_id = a.id and chosen is not null)
  );
end $$;

-- حفظ إجابة فور اختيارها
create or replace function public.save_answer(p_attempt uuid, p_question uuid, p_chosen int)
returns text
language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype; opts int;
begin
  select * into a from attempts where id = p_attempt and student_id = auth.uid();
  if not found then raise exception 'المحاولة غير موجودة'; end if;
  if a.finished_at is not null then return 'finished'; end if;

  if now() > a.deadline_at + make_interval(secs => setting_int('grace_seconds', 5)) then
    perform grade_attempt(a.id);
    return 'expired';
  end if;

  select jsonb_array_length(q.options) into opts
    from attempt_questions aq join questions q on q.id = aq.question_id
   where aq.attempt_id = p_attempt and aq.question_id = p_question;
  if opts is null then raise exception 'السؤال ليس ضمن هذا الاختبار'; end if;
  if p_chosen is not null and (p_chosen < 0 or p_chosen >= opts) then
    raise exception 'خيار غير صحيح';
  end if;

  insert into responses(attempt_id, question_id, chosen)
  values (p_attempt, p_question, p_chosen)
  on conflict (attempt_id, question_id)
  do update set chosen = excluded.chosen, answered_at = now();
  return 'ok';
end $$;

-- تسجيل مغادرة الطالب لصفحة الاختبار
create or replace function public.log_tab_leave(p_attempt uuid) returns void
language sql security definer set search_path = public as $$
  update attempts set tab_leaves = tab_leaves + 1
   where id = p_attempt and student_id = auth.uid() and finished_at is null
$$;

-- إنهاء الاختبار نهائياً
create or replace function public.finish_attempt(p_attempt uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from attempts where id = p_attempt and student_id = auth.uid()) then
    raise exception 'المحاولة غير موجودة';
  end if;
  perform grade_attempt(p_attempt);
end $$;

-- النتيجة التفصيلية (بعد الإنهاء فقط)
-- الإجابة الصحيحة تظهر فقط للسؤال الذي أخطأ فيه الطالب
create or replace function public.get_result(p_attempt uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a attempts%rowtype;
begin
  select * into a from attempts
   where id = p_attempt and (student_id = auth.uid() or is_admin());
  if not found then raise exception 'المحاولة غير موجودة'; end if;
  if a.finished_at is null then raise exception 'الاختبار لم ينتهِ بعد'; end if;

  return jsonb_build_object(
    'attempt', jsonb_build_object('id', a.id, 'subject', a.subject, 'score', a.score,
               'total', a.total, 'started_at', a.started_at, 'finished_at', a.finished_at,
               'pct', round(100.0 * a.score / nullif(a.total, 0), 1)),
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'position', aq.position, 'text', q.text, 'image_url', q.image_url, 'skill', q.skill,
        'options', (select jsonb_agg(jsonb_build_object('idx', o, 'text', q.options ->> o) order by ord)
                      from unnest(aq.option_order) with ordinality as t(o, ord)),
        'chosen', r.chosen,
        'is_correct', coalesce(r.is_correct, false),
        'points', case when coalesce(r.is_correct, false) then 1 else 0 end,
        'correct', case when coalesce(r.is_correct, false) then null else k.correct_option end,
        'explanation', k.explanation
      ) order by aq.position), '[]'::jsonb)
      from attempt_questions aq
      join questions q on q.id = aq.question_id
      left join responses r on r.attempt_id = aq.attempt_id and r.question_id = aq.question_id
      left join answer_key k on k.question_id = aq.question_id
      where aq.attempt_id = a.id)
  );
end $$;

-- تحديث آخر دخول، ويرجع هل يجب تغيير كلمة المرور
create or replace function public.touch_login() returns boolean
language sql security definer set search_path = public as $$
  update profiles set last_login = now() where id = auth.uid()
  returning must_change_password
$$;

create or replace function public.clear_must_change() returns void
language sql security definer set search_path = public as $$
  update profiles set must_change_password = false where id = auth.uid()
$$;

-- ---------- 6) تقارير المدير ----------

-- نسبة الإجابة الصحيحة لكل سؤال
create or replace function public.admin_question_stats(p_grade text, p_subject text)
returns table(question_id uuid, text text, skill text, times_answered bigint,
              correct_count bigint, correct_pct numeric)
language sql security definer stable set search_path = public as $$
  select q.id, q.text, q.skill,
         count(r.question_id),
         count(*) filter (where r.is_correct),
         round(100.0 * count(*) filter (where r.is_correct) / nullif(count(r.question_id), 0), 1)
    from questions q
    left join responses r on r.question_id = q.id and r.is_correct is not null
   where is_admin() and q.grade = p_grade and q.subject = p_subject
   group by q.id
   order by 6 asc nulls last
$$;

-- ملخص كل فصل في كل مادة
create or replace function public.admin_class_summary()
returns table(grade text, class_no smallint, subject text, students bigint,
              students_attempted bigint, attempts bigint, avg_pct numeric)
language sql security definer stable set search_path = public as $$
  select p.grade, p.class_no, s.subject,
         count(distinct p.id),
         count(distinct a.student_id),
         count(a.id),
         round(avg(100.0 * a.score / nullif(a.total, 0)), 1)
    from profiles p
    cross join (values ('math'), ('arabic'), ('science')) s(subject)
    left join attempts a on a.student_id = p.id and a.subject = s.subject
                        and a.finished_at is not null
   where is_admin() and p.role = 'student'
   group by p.grade, p.class_no, s.subject
   order by p.grade, p.class_no, s.subject
$$;

-- ---------- 7) صلاحيات تنفيذ الدوال ----------

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.is_admin(),
  public.start_attempt(text),
  public.get_attempt(uuid),
  public.save_answer(uuid, uuid, int),
  public.log_tab_leave(uuid),
  public.finish_attempt(uuid),
  public.get_result(uuid),
  public.touch_login(),
  public.clear_must_change(),
  public.admin_question_stats(text, text),
  public.admin_class_summary()
to authenticated;

-- ---------- 8) التخزين (صور الأسئلة وملفات الرفع) ----------

insert into storage.buckets (id, name, public) values
  ('question-images', 'question-images', true),    -- صور تظهر للطلاب
  ('question-uploads', 'question-uploads', false)  -- ملفات PDF/Word للمدير فقط
on conflict (id) do nothing;

create policy "admin manage question files" on storage.objects for all
  using (bucket_id in ('question-images', 'question-uploads') and public.is_admin())
  with check (bucket_id in ('question-images', 'question-uploads') and public.is_admin());

-- =====================================================================
--  بعد التشغيل: إنشاء حساب المدير
--  1) Supabase > Authentication > Users > Add user
--     بريد حقيقي لك + كلمة مرور قوية + فعّل Auto Confirm User
--  2) نفّذ السطر التالي بعد استبدال البريد:
--
--  insert into public.profiles (id, full_name, role)
--  select id, 'المدير', 'admin' from auth.users where email = 'YOUR_EMAIL@example.com';
--
--  تغيير عدد المحاولات (مثلاً 3 في الأسبوع):
--  update public.settings set value = '3' where key = 'max_attempts_per_week';
--
--  إيقاف شرط القائمة المعتمدة (يسجل أي طالب باختيار فصله بنفسه):
--  update public.settings set value = 'false' where key = 'require_allowed_list';
-- =====================================================================
