-- Rendered and run by reset-environment.sh. Supabase CLI db query executes one
-- prepared statement, so the entire preview/reset is one transactional DO
-- block. The __...__ placeholders are replaced only with validated booleans,
-- alphanumeric values, or hex-encoded UTF-8; user input never becomes syntax.
do $$
declare
  required_table text;
  v_raw_email text;
  v_account_email text;
  v_trial_email text;
  v_local_part text;
  v_domain_part text;
  v_device_hash text := nullif('__DEVICE_HASH__', '');
  v_client_ip text := nullif(convert_from(decode('__CLIENT_IP_HEX__', 'hex'), 'UTF8'), '');
  v_trial_ids uuid[] := array[]::uuid[];
  v_byok_ids uuid[] := array[]::uuid[];
  v_device_hashes text[] := array[]::text[];
  v_sub_ids uuid[] := array[]::uuid[];
  v_sub_order_ids text[] := array[]::text[];
  v_sub_customer_ids text[] := array[]::text[];
  v_sub_license_hashes text[] := array[]::text[];
  v_identity_keys text[] := array[]::text[];
  v_rate_keys text[] := array[]::text[];
  v_device_claim_count bigint := 0;
  v_trial_code_count bigint := 0;
  v_contact_count bigint := 0;
  v_idempotency_count bigint := 0;
  v_rate_limit_count bigint := 0;
begin
  foreach required_table in array array[
    'public.trial_grants',
    'public.trial_codes',
    'public.trial_device_claims',
    'public.byok_trial_grants',
    'public.byok_trial_usage_events',
    'public.onboarding_contacts',
    'public.subscriptions',
    'public.generation_log',
    'public.idempotency_cache',
    'public.rate_limits',
    'public.pending_license_keys'
  ] loop
    if to_regclass(required_table) is null then
      raise exception 'Required table % is missing. Apply the current Zerro migrations to this environment first.', required_table;
    end if;
  end loop;

  v_raw_email := convert_from(decode('__EMAIL_HEX__', 'hex'), 'UTF8');
  v_account_email := lower(trim(v_raw_email));
  v_local_part := split_part(v_account_email, '@', 1);
  v_domain_part := split_part(v_account_email, '@', 2);
  v_trial_email := case
    when v_domain_part in ('gmail.com', 'googlemail.com') then
      replace(split_part(v_local_part, '+', 1), '.', '') || '@gmail.com'
    else split_part(v_local_part, '+', 1) || '@' || v_domain_part
  end;

  select coalesce(array_agg(distinct tg.id), array[]::uuid[])
    into v_trial_ids
  from public.trial_grants tg
  where tg.email_normalized = v_trial_email
     or (v_device_hash is not null and tg.device_id_hash = v_device_hash);

  select coalesce(array_agg(distinct bg.id), array[]::uuid[])
    into v_byok_ids
  from public.byok_trial_grants bg
  where v_device_hash is not null and bg.device_id_hash = v_device_hash;

  select coalesce(array_agg(distinct hashes.device_id_hash), array[]::text[])
    into v_device_hashes
  from (
    select v_device_hash as device_id_hash
    union all
    select tg.device_id_hash from public.trial_grants tg where tg.id = any(v_trial_ids)
    union all
    select bg.device_id_hash from public.byok_trial_grants bg where bg.id = any(v_byok_ids)
  ) hashes
  where hashes.device_id_hash is not null;

  select
    coalesce(array_agg(distinct s.id), array[]::uuid[]),
    coalesce(array_agg(distinct s.ls_order_id) filter (where s.ls_order_id is not null), array[]::text[]),
    coalesce(array_agg(distinct s.ls_customer_id) filter (where s.ls_customer_id is not null), array[]::text[]),
    coalesce(array_agg(distinct s.license_key_hash) filter (where s.license_key_hash is not null), array[]::text[])
  into v_sub_ids, v_sub_order_ids, v_sub_customer_ids, v_sub_license_hashes
  from public.subscriptions s
  where lower(trim(s.email_normalized)) = v_account_email;

  select coalesce(array_agg(distinct keys.identity_key), array[]::text[])
    into v_identity_keys
  from (
    select 'generate:trial:' || id::text as identity_key from unnest(v_trial_ids) id
    union all
    select 'convert:trial:' || id::text from unnest(v_trial_ids) id
    union all
    select 'generate:sub:' || id::text from unnest(v_sub_ids) id where __INCLUDE_BILLING__
    union all
    select 'convert:sub:' || id::text from unnest(v_sub_ids) id where __INCLUDE_BILLING__
  ) keys;

  select coalesce(array_agg(distinct keys.key), array[]::text[])
    into v_rate_keys
  from (
    select unnest(v_identity_keys) as key
    union all select 'trial:email:' || encode(digest(v_trial_email, 'sha256'), 'hex')
    union all select 'trial:send:' || encode(digest(v_trial_email, 'sha256'), 'hex')
    union all select 'trial:ip:' || v_client_ip where v_client_ip is not null
    union all select 'byok-trial:device:' || v_device_hash where v_device_hash is not null
    union all select 'byok-trial:ip:' || encode(digest(v_client_ip, 'sha256'), 'hex') where v_client_ip is not null
    union all select 'session:ip:' || v_client_ip where __INCLUDE_BILLING__ and v_client_ip is not null
    union all select 'session:keyhash:' || key_hash from unnest(v_sub_license_hashes) key_hash where __INCLUDE_BILLING__
  ) keys;

  select count(*) into v_device_claim_count
  from public.trial_device_claims c where c.device_id_hash = any(v_device_hashes);
  select count(*) into v_trial_code_count
  from public.trial_codes tc where tc.email_normalized = v_trial_email;
  select count(*) into v_contact_count
  from public.onboarding_contacts oc where oc.email_normalized = v_trial_email;
  select count(*) into v_idempotency_count
  from public.idempotency_cache ic where ic.identity_key = any(v_identity_keys);
  select count(*) into v_rate_limit_count
  from public.rate_limits rl where rl.key = any(v_rate_keys);

  raise notice '%', jsonb_pretty(jsonb_build_object(
    'environment', '__ENVIRONMENT__',
    'mode', case when __EXECUTE__ then 'execute' else 'preview' end,
    'account_email', v_account_email,
    'trial_email', v_trial_email,
    'device_hash_present', v_device_hash is not null,
    'client_ip_present', v_client_ip is not null,
    'include_billing', __INCLUDE_BILLING__,
    'matched_trial_grants', cardinality(v_trial_ids),
    'matched_byok_grants', cardinality(v_byok_ids),
    'matched_device_claims', v_device_claim_count,
    'matched_trial_codes', v_trial_code_count,
    'matched_onboarding_contacts', v_contact_count,
    'matched_subscriptions', cardinality(v_sub_ids),
    'matched_idempotency_rows', v_idempotency_count,
    'matched_rate_limit_rows', v_rate_limit_count
  ));

  if not __EXECUTE__ then
    return;
  end if;

  delete from public.idempotency_cache ic where ic.identity_key = any(v_identity_keys);
  delete from public.rate_limits rl where rl.key = any(v_rate_keys);

  if __INCLUDE_BILLING__ then
    delete from public.generation_log gl where gl.subscription_id = any(v_sub_ids);
    delete from public.pending_license_keys plk
    where plk.ls_order_id = any(v_sub_order_ids)
       or plk.ls_customer_id = any(v_sub_customer_ids);
    delete from public.subscriptions s where s.id = any(v_sub_ids);
  end if;

  delete from public.trial_grants tg where tg.id = any(v_trial_ids);
  delete from public.byok_trial_grants bg where bg.id = any(v_byok_ids);
  delete from public.trial_device_claims c where c.device_id_hash = any(v_device_hashes);
  delete from public.trial_codes tc where tc.email_normalized = v_trial_email;
  delete from public.onboarding_contacts oc where oc.email_normalized = v_trial_email;
end
$$;
