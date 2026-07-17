-- ============================================================================
-- Alltech Biomassa — política de Storage do bucket "evidencias"
-- ============================================================================
-- Rode isso DEPOIS de já ter criado o bucket "evidencias" (privado) no painel
-- do Supabase (Storage → New bucket → nome "evidencias" → Public: desmarcado).
--
-- O que isso faz:
--   - Libera a chave pública (anon) para ENVIAR arquivos (INSERT) no bucket.
--   - NÃO libera leitura pública nem listagem — ninguém acessa foto por link
--     direto. Visualizar (quando formos plugar isso no painel) vai exigir
--     gerar uma "signed URL" temporária, com uma chave que tenha permissão
--     de leitura — isso é um passo à parte, para quando conectarmos o painel.
-- ============================================================================

CREATE POLICY "permite upload publico no bucket evidencias"
ON storage.objects FOR INSERT
TO anon
WITH CHECK (bucket_id = 'evidencias');
