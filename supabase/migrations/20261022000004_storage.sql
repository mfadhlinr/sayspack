-- =====================================================================
-- Sayspack Management System — Migrasi 4: Storage bukti transaksi (khusus Supabase)
-- Bucket privat; file dibuka lewat signed URL berumur 60 detik.
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bukti', 'bukti', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy "bukti: owner unggah" on storage.objects for insert to authenticated
  with check (bucket_id = 'bukti' and public.is_owner());
create policy "bukti: owner & investor lihat" on storage.objects for select to authenticated
  using (bucket_id = 'bukti' and public.can_read_reports());
-- Owner boleh menghapus file yatim (misal unggahan yang transaksinya gagal disimpan).
-- Bukti yang sudah tertaut ke transaksi tetap tercatat path-nya di audit log.
create policy "bukti: owner hapus" on storage.objects for delete to authenticated
  using (bucket_id = 'bukti' and public.is_owner());
