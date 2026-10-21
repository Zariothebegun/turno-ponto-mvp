drop index if exists public.qr_sessions_expiry_idx;
create index if not exists qr_sessions_organization_expiry_idx on public.qr_sessions (organization_id, expires_at);
create index if not exists qr_sessions_created_by_idx on public.qr_sessions (created_by);
create index if not exists qr_session_uses_profile_idx on public.qr_session_uses (profile_id);
create policy "QR session uses are never directly accessible"
on public.qr_session_uses for all to authenticated
using (false) with check (false);
