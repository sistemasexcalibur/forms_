-- ============================================================================
-- Alltech Biomassa — função de sincronização do PWA + trava de segurança (RLS)
-- ============================================================================
-- Rode isso DEPOIS de já ter rodado o schema_biomassa.sql no projeto Supabase.
--
-- O que este arquivo faz:
--   1. Liga Row Level Security (RLS) em todas as tabelas — sem isso, qualquer
--      pessoa com a chave pública (sb_publishable_...) do app teria acesso
--      livre de leitura/escrita/exclusão em todas as tabelas.
--   2. NÃO cria políticas de acesso direto às tabelas para o público — ou
--      seja, o app não consegue ler/gravar direto nas tabelas.
--   3. Cria UMA função (sincronizar_visita) que é o único portão de entrada:
--      o PWA manda um pacote JSON com os dados da visita, e essa função faz
--      todos os inserts/updates nas 8 tabelas relacionadas, dentro de uma
--      única transação atômica (ou grava tudo, ou não grava nada).
--   4. Libera essa função (só ela) para a chave pública poder chamar.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Trava as tabelas
-- ----------------------------------------------------------------------------
ALTER TABLE especialistas             ENABLE ROW LEVEL SECURITY;
ALTER TABLE propriedades              ENABLE ROW LEVEL SECURITY;
ALTER TABLE proprietarios             ENABLE ROW LEVEL SECURITY;
ALTER TABLE propriedade_proprietario  ENABLE ROW LEVEL SECURITY;
ALTER TABLE visitas                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE floresta_atual            ENABLE ROW LEVEL SECURITY;
ALTER TABLE potencial_futuro          ENABLE ROW LEVEL SECURITY;
ALTER TABLE logistica                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE ambiental                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE evidencias_midia          ENABLE ROW LEVEL SECURITY;
ALTER TABLE geolocalizacao_visita     ENABLE ROW LEVEL SECURITY;
ALTER TABLE pontuacao                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE aptidao_comercial         ENABLE ROW LEVEL SECURITY;
ALTER TABLE fila_sincronizacao        ENABLE ROW LEVEL SECURITY;
-- (RLS ligado sem nenhuma política = ninguém além do dono do banco acessa
-- direto. É exatamente o que queremos: só a função abaixo tem passagem.)

-- ----------------------------------------------------------------------------
-- 2) Auxiliar: converte texto pra número sem quebrar a transação se o texto
--    não for um número válido (ex.: campo de incremento médio, que no PWA
--    é texto livre — "ex: 400 a 500 m³/ano" — mas na tabela é numeric).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION safe_numeric(txt text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN txt::numeric;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- 3) A função principal
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sincronizar_visita(p jsonb)
RETURNS TABLE (out_visita_id uuid, out_propriedade_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uuid_dispositivo uuid := (p->>'uuid_dispositivo')::uuid;
  v_visita_id uuid;
  v_propriedade_id uuid;
  v_proprietario_id uuid;
  v_especialista_id uuid;
  v_gps jsonb := p->'gps_visita';
  v_total smallint;
  v_faixa text;
  v_prioridade classificacao_prioridade;
  v_modelo modelo_interesse_tipo;
BEGIN
  IF v_uuid_dispositivo IS NULL THEN
    RAISE EXCEPTION 'uuid_dispositivo é obrigatório';
  END IF;

  -- especialista: encontra por nome ou cria
  IF (p->>'especialista') IS NOT NULL AND (p->>'especialista') <> '' THEN
    SELECT id INTO v_especialista_id FROM especialistas WHERE nome = p->>'especialista' LIMIT 1;
    IF v_especialista_id IS NULL THEN
      INSERT INTO especialistas (nome) VALUES (p->>'especialista') RETURNING id INTO v_especialista_id;
    END IF;
  END IF;

  -- já existe uma visita com esse uuid_dispositivo? (reenvio/retry)
  SELECT id, propriedade_id INTO v_visita_id, v_propriedade_id
  FROM visitas WHERE uuid_dispositivo = v_uuid_dispositivo;

  IF v_visita_id IS NULL THEN
    -- primeira vez: cria propriedade e proprietário novos
    INSERT INTO propriedades (
      nome_fazenda, endereco_completo, municipio, estado, regiao,
      area_total_ha, area_agricola_ha, area_pastagem_ha, area_florestal_atual_ha,
      area_disponivel_floresta_ha, area_arrendada_ha, area_propria_ha, atividade_principal,
      latitude, longitude, precisao_gps_m
    ) VALUES (
      COALESCE(p->>'nome_fazenda', 'Sem nome'), p->>'endereco', p->>'municipio', p->>'estado', p->>'regiao',
      safe_numeric(p->>'area_total'), safe_numeric(p->>'area_agricola'), safe_numeric(p->>'area_pastagem'),
      safe_numeric(p->>'area_florestal_atual'), safe_numeric(p->>'area_disponivel_floresta'),
      safe_numeric(p->>'area_arrendada'), safe_numeric(p->>'area_propria'), p->>'atividade_principal',
      CASE WHEN v_gps IS NOT NULL THEN (v_gps->>'lat')::double precision END,
      CASE WHEN v_gps IS NOT NULL THEN (v_gps->>'lon')::double precision END,
      CASE WHEN v_gps IS NOT NULL THEN safe_numeric(v_gps->>'acc') END
    ) RETURNING id INTO v_propriedade_id;

    IF (p->>'proprietario') IS NOT NULL AND (p->>'proprietario') <> '' THEN
      INSERT INTO proprietarios (nome, cpf_cnpj, telefone, whatsapp)
      VALUES (p->>'proprietario', p->>'cpf_cnpj', p->>'telefone', p->>'whatsapp')
      RETURNING id INTO v_proprietario_id;
      INSERT INTO propriedade_proprietario (propriedade_id, proprietario_id) VALUES (v_propriedade_id, v_proprietario_id);
    END IF;

    INSERT INTO visitas (propriedade_id, especialista_id, data_visita, hora_inicio, hora_termino, origem_contato, uuid_dispositivo, status_sincronizacao)
    VALUES (
      v_propriedade_id, v_especialista_id,
      NULLIF(p->>'data_visita','')::date, NULLIF(p->>'hora_inicio','')::time, NULLIF(p->>'hora_termino','')::time,
      p->>'origem_contato', v_uuid_dispositivo, 'sincronizado'
    ) RETURNING id INTO v_visita_id;
  ELSE
    -- reenvio: atualiza os registros já existentes em vez de duplicar
    UPDATE propriedades SET
      nome_fazenda = COALESCE(p->>'nome_fazenda', nome_fazenda),
      endereco_completo = p->>'endereco', municipio = p->>'municipio', estado = p->>'estado', regiao = p->>'regiao',
      area_total_ha = safe_numeric(p->>'area_total'), area_agricola_ha = safe_numeric(p->>'area_agricola'),
      area_pastagem_ha = safe_numeric(p->>'area_pastagem'), area_florestal_atual_ha = safe_numeric(p->>'area_florestal_atual'),
      area_disponivel_floresta_ha = safe_numeric(p->>'area_disponivel_floresta'), area_arrendada_ha = safe_numeric(p->>'area_arrendada'),
      area_propria_ha = safe_numeric(p->>'area_propria'), atividade_principal = p->>'atividade_principal',
      latitude = CASE WHEN v_gps IS NOT NULL THEN (v_gps->>'lat')::double precision ELSE latitude END,
      longitude = CASE WHEN v_gps IS NOT NULL THEN (v_gps->>'lon')::double precision ELSE longitude END,
      precisao_gps_m = CASE WHEN v_gps IS NOT NULL THEN safe_numeric(v_gps->>'acc') ELSE precisao_gps_m END,
      atualizado_em = now()
    WHERE id = v_propriedade_id;

    SELECT proprietario_id INTO v_proprietario_id FROM propriedade_proprietario WHERE propriedade_id = v_propriedade_id LIMIT 1;
    IF v_proprietario_id IS NOT NULL THEN
      UPDATE proprietarios SET nome = COALESCE(p->>'proprietario', nome), cpf_cnpj = p->>'cpf_cnpj', telefone = p->>'telefone', whatsapp = p->>'whatsapp'
      WHERE id = v_proprietario_id;
    ELSIF (p->>'proprietario') IS NOT NULL AND (p->>'proprietario') <> '' THEN
      INSERT INTO proprietarios (nome, cpf_cnpj, telefone, whatsapp)
      VALUES (p->>'proprietario', p->>'cpf_cnpj', p->>'telefone', p->>'whatsapp')
      RETURNING id INTO v_proprietario_id;
      INSERT INTO propriedade_proprietario (propriedade_id, proprietario_id) VALUES (v_propriedade_id, v_proprietario_id);
    END IF;

    UPDATE visitas SET
      especialista_id = COALESCE(v_especialista_id, especialista_id),
      data_visita = NULLIF(p->>'data_visita','')::date, hora_inicio = NULLIF(p->>'hora_inicio','')::time,
      hora_termino = NULLIF(p->>'hora_termino','')::time, origem_contato = p->>'origem_contato',
      status_sincronizacao = 'sincronizado', atualizado_em = now()
    WHERE id = v_visita_id;
  END IF;

  -- floresta_atual (upsert por visita_id)
  INSERT INTO floresta_atual (
    visita_id, possui_eucalipto, area_plantada_ha, idade_media_anos, material_genetico,
    volume_estimado_m3, incremento_medio_m3_ano, incidencia_falhas_plantio_pct, homogeneidade_individuos,
    individuos_idades_diferentes, possui_patogeno_doenca, patogeno_qual, declividade_media,
    macico_proximo_app_rl, colheita_indicada, destino_atual_madeira, ira_conduzir_brotacao,
    ciclo_plantio, vencimento_contrato
  ) VALUES (
    v_visita_id, (p->>'possui_eucalipto')::boolean, safe_numeric(p->>'area_plantada'), safe_numeric(p->>'idade_media'),
    p->>'material_genetico', safe_numeric(p->>'volume_estimado'), safe_numeric(p->>'incremento_medio'),
    safe_numeric(p->>'incidencia_falhas'), p->>'homogeneidade', (p->>'individuos_idades_diferentes')::boolean,
    (p->>'possui_patogeno')::boolean, p->>'patogeno_qual', p->>'declividade', (p->>'macico_app_rl')::boolean,
    p->>'colheita_indicada', p->>'destino_madeira', (p->>'conduzira_brotacao')::boolean, p->>'ciclo_plantio', p->>'vencimento_contrato'
  )
  ON CONFLICT (visita_id) DO UPDATE SET
    possui_eucalipto = EXCLUDED.possui_eucalipto, area_plantada_ha = EXCLUDED.area_plantada_ha,
    idade_media_anos = EXCLUDED.idade_media_anos, material_genetico = EXCLUDED.material_genetico,
    volume_estimado_m3 = EXCLUDED.volume_estimado_m3, incremento_medio_m3_ano = EXCLUDED.incremento_medio_m3_ano,
    incidencia_falhas_plantio_pct = EXCLUDED.incidencia_falhas_plantio_pct, homogeneidade_individuos = EXCLUDED.homogeneidade_individuos,
    individuos_idades_diferentes = EXCLUDED.individuos_idades_diferentes, possui_patogeno_doenca = EXCLUDED.possui_patogeno_doenca,
    patogeno_qual = EXCLUDED.patogeno_qual, declividade_media = EXCLUDED.declividade_media,
    macico_proximo_app_rl = EXCLUDED.macico_proximo_app_rl, colheita_indicada = EXCLUDED.colheita_indicada,
    destino_atual_madeira = EXCLUDED.destino_atual_madeira, ira_conduzir_brotacao = EXCLUDED.ira_conduzir_brotacao,
    ciclo_plantio = EXCLUDED.ciclo_plantio, vencimento_contrato = EXCLUDED.vencimento_contrato;

  -- modelo_interesse: normaliza "Compra de madeira" (PWA) -> 'Compra de Madeira' (enum)
  v_modelo := CASE lower(trim(p->>'modelo_interesse'))
    WHEN 'arrendamento' THEN 'Arrendamento'
    WHEN 'parceria' THEN 'Parceria'
    WHEN 'compra de madeira' THEN 'Compra de Madeira'
    WHEN 'fomento' THEN 'Fomento'
    ELSE NULL
  END::modelo_interesse_tipo;

  -- potencial_futuro (upsert por visita_id)
  INSERT INTO potencial_futuro (
    visita_id, interesse_novos_plantios, area_disponivel_expansao_ha, prazo_implantacao, modelo_interesse,
    interesse_contrato_longo_prazo, volume_potencial_ton_ano, preco_esperado_rs_ton, comentarios
  ) VALUES (
    v_visita_id, (p->>'interesse_novos_plantios')::boolean, safe_numeric(p->>'area_disponivel_expansao'),
    p->>'prazo_implantacao', v_modelo, (p->>'contrato_longo_prazo')::boolean,
    safe_numeric(p->>'volume_potencial'), safe_numeric(p->>'preco_esperado'), p->>'comentarios_potencial'
  )
  ON CONFLICT (visita_id) DO UPDATE SET
    interesse_novos_plantios = EXCLUDED.interesse_novos_plantios, area_disponivel_expansao_ha = EXCLUDED.area_disponivel_expansao_ha,
    prazo_implantacao = EXCLUDED.prazo_implantacao, modelo_interesse = EXCLUDED.modelo_interesse,
    interesse_contrato_longo_prazo = EXCLUDED.interesse_contrato_longo_prazo, volume_potencial_ton_ano = EXCLUDED.volume_potencial_ton_ano,
    preco_esperado_rs_ton = EXCLUDED.preco_esperado_rs_ton, comentarios = EXCLUDED.comentarios;

  -- logistica (upsert por visita_id)
  INSERT INTO logistica (
    visita_id, tipo_acesso, distancia_rodovia_km, distancia_fabrica_km, pct_via_excelente, pct_via_boa, pct_via_ruim,
    possui_pedagio, valor_pedagio_eixo_rs, possui_energia_eletrica, possui_equipamentos_proprios, quais_equipamentos,
    possui_area_carregamento, possui_area_patio_intermediario, tempo_medio_ate_unidade_horas, custo_logistico_rs_ton, observacoes
  ) VALUES (
    v_visita_id, p->>'tipo_acesso', safe_numeric(p->>'distancia_rodovia'), safe_numeric(p->>'distancia_fabrica'),
    safe_numeric(p->>'pct_via_excelente'), safe_numeric(p->>'pct_via_boa'), safe_numeric(p->>'pct_via_ruim'),
    (p->>'possui_pedagio')::boolean, safe_numeric(p->>'valor_pedagio'), (p->>'possui_energia')::boolean,
    (p->>'possui_equipamentos')::boolean, p->>'quais_equipamentos', (p->>'area_carregamento')::boolean,
    (p->>'area_patio')::boolean, safe_numeric(p->>'tempo_medio_unidade'), safe_numeric(p->>'custo_logistico'), p->>'observacoes_logisticas'
  )
  ON CONFLICT (visita_id) DO UPDATE SET
    tipo_acesso = EXCLUDED.tipo_acesso, distancia_rodovia_km = EXCLUDED.distancia_rodovia_km, distancia_fabrica_km = EXCLUDED.distancia_fabrica_km,
    pct_via_excelente = EXCLUDED.pct_via_excelente, pct_via_boa = EXCLUDED.pct_via_boa, pct_via_ruim = EXCLUDED.pct_via_ruim,
    possui_pedagio = EXCLUDED.possui_pedagio, valor_pedagio_eixo_rs = EXCLUDED.valor_pedagio_eixo_rs,
    possui_energia_eletrica = EXCLUDED.possui_energia_eletrica, possui_equipamentos_proprios = EXCLUDED.possui_equipamentos_proprios,
    quais_equipamentos = EXCLUDED.quais_equipamentos, possui_area_carregamento = EXCLUDED.possui_area_carregamento,
    possui_area_patio_intermediario = EXCLUDED.possui_area_patio_intermediario, tempo_medio_ate_unidade_horas = EXCLUDED.tempo_medio_ate_unidade_horas,
    custo_logistico_rs_ton = EXCLUDED.custo_logistico_rs_ton, observacoes = EXCLUDED.observacoes;

  -- ambiental (upsert por visita_id)
  INSERT INTO ambiental (visita_id, existe_reserva_legal, car_regularizado, existem_restricoes, restricoes_descricao)
  VALUES (v_visita_id, (p->>'existe_reserva_legal')::boolean, (p->>'car_regularizado')::boolean,
          (p->>'existem_restricoes')::boolean, p->>'restricoes_descricao')
  ON CONFLICT (visita_id) DO UPDATE SET
    existe_reserva_legal = EXCLUDED.existe_reserva_legal, car_regularizado = EXCLUDED.car_regularizado,
    existem_restricoes = EXCLUDED.existem_restricoes, restricoes_descricao = EXCLUDED.restricoes_descricao;

  -- pontuacao: calcula total e classificação antes de gravar
  v_total := COALESCE((p->>'score_area')::smallint, 0) + COALESCE((p->>'score_interesse')::smallint, 0)
    + COALESCE((p->>'score_logistica')::smallint, 0) + COALESCE((p->>'score_producao')::smallint, 0)
    + COALESCE((p->>'score_ambiental')::smallint, 0);
  IF v_total >= 80 THEN v_faixa := 'Ótima (80-100)'; v_prioridade := 'Prioridade Alta';
  ELSIF v_total >= 70 THEN v_faixa := 'Boa (70-79)'; v_prioridade := 'Prioridade Media';
  ELSE v_faixa := 'Ruim (abaixo de 70)'; v_prioridade := 'Prioridade Baixa';
  END IF;

  INSERT INTO pontuacao (
    visita_id, area_disponivel_score, interesse_comercial_score, logistica_score, potencial_producao_score,
    aspectos_ambientais_score, classificacao_faixa, classificacao_final, potencial_fornecimento,
    capacidade_estimada_ton_ano, recomendacao, resumo_executivo, proximas_acoes
  ) VALUES (
    v_visita_id, (p->>'score_area')::smallint, (p->>'score_interesse')::smallint, (p->>'score_logistica')::smallint,
    (p->>'score_producao')::smallint, (p->>'score_ambiental')::smallint, v_faixa, v_prioridade,
    p->>'potencial_fornecimento', safe_numeric(p->>'capacidade_estimada'), p->>'recomendacao',
    p->>'resumo_executivo', p->>'proximas_acoes'
  )
  ON CONFLICT (visita_id) DO UPDATE SET
    area_disponivel_score = EXCLUDED.area_disponivel_score, interesse_comercial_score = EXCLUDED.interesse_comercial_score,
    logistica_score = EXCLUDED.logistica_score, potencial_producao_score = EXCLUDED.potencial_producao_score,
    aspectos_ambientais_score = EXCLUDED.aspectos_ambientais_score, classificacao_faixa = EXCLUDED.classificacao_faixa,
    classificacao_final = EXCLUDED.classificacao_final, potencial_fornecimento = EXCLUDED.potencial_fornecimento,
    capacidade_estimada_ton_ano = EXCLUDED.capacidade_estimada_ton_ano, recomendacao = EXCLUDED.recomendacao,
    resumo_executivo = EXCLUDED.resumo_executivo, proximas_acoes = EXCLUDED.proximas_acoes;

  -- geolocalizacao_visita (upsert por visita_id) — só grava se o GPS foi capturado
  IF v_gps IS NOT NULL THEN
    INSERT INTO geolocalizacao_visita (visita_id, latitude, longitude, precisao_m, capturado_em, status_sincronizacao)
    VALUES (
      v_visita_id, (v_gps->>'lat')::double precision, (v_gps->>'lon')::double precision, safe_numeric(v_gps->>'acc'),
      to_timestamp(((v_gps->>'quando')::bigint) / 1000.0), 'sincronizado'
    )
    ON CONFLICT (visita_id) DO UPDATE SET
      latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude, precisao_m = EXCLUDED.precisao_m,
      capturado_em = EXCLUDED.capturado_em, status_sincronizacao = 'sincronizado';
  END IF;

  -- evidencias_midia: recebe os caminhos das fotos já enviadas ao Storage
  -- (o upload em si acontece direto do celular pro bucket; aqui só
  -- registramos qual arquivo corresponde a qual tipo de evidência).
  IF p->'evidencias' IS NOT NULL AND jsonb_array_length(p->'evidencias') > 0 THEN
    DELETE FROM evidencias_midia WHERE visita_id = v_visita_id;
    INSERT INTO evidencias_midia (visita_id, tipo, url_arquivo, capturado_em, status_sincronizacao)
    SELECT v_visita_id, (e->>'tipo')::tipo_evidencia, e->>'path', now(), 'sincronizado'
    FROM jsonb_array_elements(p->'evidencias') AS e;
  END IF;

  RETURN QUERY SELECT v_visita_id, v_propriedade_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4) Libera só essa função para a chave pública (anon) chamar
-- ----------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION sincronizar_visita(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION sincronizar_visita(jsonb) TO authenticated;
