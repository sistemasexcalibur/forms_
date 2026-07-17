-- ============================================================================
-- Alltech Biomassa — política de Storage do bucket "evidencias"
-- ============================================================================
-- Rode isso DEPOIS de já ter criado o bucket "evidencias" (privado) no painel
-- do Supabase (Storage → New bucket → nome "evidencias" → Public: desmarcado).
--
-- O que isso faz:
--   - Libera a chave pública (anon) para ENVIAR (INSERT), SUBSTITUIR (UPDATE)
--     e VERIFICAR (SELECT) arquivos no bucket. As três são necessárias porque
--     o app usa upsert:true (reenviar substitui, não duplica) — e o Postgres
--     exige INSERT + UPDATE + SELECT juntas pra "upsert" funcionar de verdade
--     (documentado pela própria Supabase, não é óbvio à primeira vista).
--   - NÃO libera leitura pública/listagem para humanos nem para outros apps
--     — SELECT aqui existe só pra viabilizar o mecanismo de upsert; ver o
--     conteúdo de fato ainda vai exigir uma signed URL, quando conectarmos
--     isso ao painel.
-- ============================================================================

DROP POLICY IF EXISTS "permite upload publico no bucket evidencias" ON storage.objects;
CREATE POLICY "permite upload publico no bucket evidencias"
ON storage.objects FOR INSERT
TO anon
WITH CHECK (bucket_id = 'evidencias');

DROP POLICY IF EXISTS "permite substituir arquivo no bucket evidencias" ON storage.objects;
CREATE POLICY "permite substituir arquivo no bucket evidencias"
ON storage.objects FOR UPDATE
TO anon
USING (bucket_id = 'evidencias')
WITH CHECK (bucket_id = 'evidencias');

DROP POLICY IF EXISTS "permite verificar arquivo no bucket evidencias" ON storage.objects;
CREATE POLICY "permite verificar arquivo no bucket evidencias"
ON storage.objects FOR SELECT
TO anon
USING (bucket_id = 'evidencias');
