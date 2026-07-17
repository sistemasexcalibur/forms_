-- ============================================================================
-- Alltech Biomassa — busca reversa (banco → PWA)
-- ============================================================================
-- Rode isso DEPOIS do schema_biomassa.sql e do sync_function.sql.
--
-- Esse é o caminho contrário do que já tínhamos: em vez do celular mandar
-- dados pro banco, essa função devolve TODAS as visitas já sincronizadas,
-- remontadas no mesmo formato "achatado" que o formulário usa. É o que
-- permite: trocar de celular, limpar o app sem querer, ou abrir de um
-- aparelho novo — e continuar de onde a visita parou, em vez de perder
-- o que já tinha sido preenchido e enviado.
--
-- Segue o mesmo modelo de segurança das outras funções: acesso direto às
-- tabelas continua bloqueado, só essa função (com SECURITY DEFINER) pode
-- ler os dados, e só ela é liberada pra chave pública.
-- ============================================================================

CREATE OR REPLACE FUNCTION listar_visitas()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT COALESCE(jsonb_agg(
    (
      jsonb_build_object(
        'uuid_dispositivo', v.uuid_dispositivo,
        'status_sincronizacao', v.status_sincronizacao,
        'atualizado_em', v.atualizado_em,
        'nome_fazenda', p.nome_fazenda,
        'endereco', p.endereco_completo,
        'municipio', p.municipio,
        'estado', p.estado,
        'regiao', p.regiao,
        'area_total', p.area_total_ha,
        'area_agricola', p.area_agricola_ha,
        'area_pastagem', p.area_pastagem_ha,
        'area_florestal_atual', p.area_florestal_atual_ha,
        'area_disponivel_floresta', p.area_disponivel_floresta_ha,
        'area_arrendada', p.area_arrendada_ha,
        'area_propria', p.area_propria_ha,
        'atividade_principal', p.atividade_principal,
        'proprietario', (SELECT pr.nome FROM propriedade_proprietario pp JOIN proprietarios pr ON pr.id = pp.proprietario_id WHERE pp.propriedade_id = p.id LIMIT 1),
        'cpf_cnpj', (SELECT pr.cpf_cnpj FROM propriedade_proprietario pp JOIN proprietarios pr ON pr.id = pp.proprietario_id WHERE pp.propriedade_id = p.id LIMIT 1),
        'telefone', (SELECT pr.telefone FROM propriedade_proprietario pp JOIN proprietarios pr ON pr.id = pp.proprietario_id WHERE pp.propriedade_id = p.id LIMIT 1),
        'whatsapp', (SELECT pr.whatsapp FROM propriedade_proprietario pp JOIN proprietarios pr ON pr.id = pp.proprietario_id WHERE pp.propriedade_id = p.id LIMIT 1),
        'data_visita', to_char(v.data_visita, 'YYYY-MM-DD'),
        'hora_inicio', to_char(v.hora_inicio, 'HH24:MI'),
        'hora_termino', to_char(v.hora_termino, 'HH24:MI'),
        'origem_contato', v.origem_contato,
        'especialista', esp.nome
      )
      ||
      jsonb_build_object(
        'possui_eucalipto', fa.possui_eucalipto,
        'area_plantada', fa.area_plantada_ha,
        'idade_media', fa.idade_media_anos,
        'material_genetico', fa.material_genetico,
        'volume_estimado', fa.volume_estimado_m3,
        'incremento_medio', fa.incremento_medio_m3_ano,
        'incidencia_falhas', fa.incidencia_falhas_plantio_pct,
        'homogeneidade', fa.homogeneidade_individuos,
        'individuos_idades_diferentes', fa.individuos_idades_diferentes,
        'possui_patogeno', fa.possui_patogeno_doenca,
        'patogeno_qual', fa.patogeno_qual,
        'declividade', fa.declividade_media,
        'macico_app_rl', fa.macico_proximo_app_rl,
        'colheita_indicada', fa.colheita_indicada,
        'destino_madeira', fa.destino_atual_madeira,
        'conduzira_brotacao', fa.ira_conduzir_brotacao,
        'ciclo_plantio', fa.ciclo_plantio,
        'vencimento_contrato', fa.vencimento_contrato
      )
      ||
      jsonb_build_object(
        'interesse_novos_plantios', pf.interesse_novos_plantios,
        'area_disponivel_expansao', pf.area_disponivel_expansao_ha,
        'prazo_implantacao', pf.prazo_implantacao,
        'modelo_interesse', pf.modelo_interesse,
        'contrato_longo_prazo', pf.interesse_contrato_longo_prazo,
        'volume_potencial', pf.volume_potencial_ton_ano,
        'preco_esperado', pf.preco_esperado_rs_ton,
        'comentarios_potencial', pf.comentarios,
        'tipo_acesso', lg.tipo_acesso,
        'distancia_rodovia', lg.distancia_rodovia_km,
        'distancia_fabrica', lg.distancia_fabrica_km,
        'pct_via_excelente', lg.pct_via_excelente,
        'pct_via_boa', lg.pct_via_boa,
        'pct_via_ruim', lg.pct_via_ruim,
        'possui_pedagio', lg.possui_pedagio,
        'valor_pedagio', lg.valor_pedagio_eixo_rs,
        'possui_energia', lg.possui_energia_eletrica,
        'possui_equipamentos', lg.possui_equipamentos_proprios,
        'quais_equipamentos', lg.quais_equipamentos,
        'area_carregamento', lg.possui_area_carregamento,
        'area_patio', lg.possui_area_patio_intermediario,
        'tempo_medio_unidade', lg.tempo_medio_ate_unidade_horas,
        'custo_logistico', lg.custo_logistico_rs_ton,
        'observacoes_logisticas', lg.observacoes
      )
      ||
      jsonb_build_object(
        'existe_reserva_legal', am.existe_reserva_legal,
        'car_regularizado', am.car_regularizado,
        'existem_restricoes', am.existem_restricoes,
        'restricoes_descricao', am.restricoes_descricao,
        'potencial_fornecimento', pt.potencial_fornecimento,
        'capacidade_estimada', pt.capacidade_estimada_ton_ano,
        'score_area', pt.area_disponivel_score,
        'score_interesse', pt.interesse_comercial_score,
        'score_logistica', pt.logistica_score,
        'score_producao', pt.potencial_producao_score,
        'score_ambiental', pt.aspectos_ambientais_score,
        'recomendacao', pt.recomendacao,
        'resumo_executivo', pt.resumo_executivo,
        'proximas_acoes', pt.proximas_acoes,
        'gps_visita', CASE WHEN gv.latitude IS NOT NULL THEN
          jsonb_build_object('lat', gv.latitude, 'lon', gv.longitude, 'acc', gv.precisao_m, 'quando', floor(extract(epoch FROM gv.capturado_em) * 1000))
          ELSE NULL END,
        'evidencias', COALESCE(
          (SELECT jsonb_agg(jsonb_build_object('tipo', em.tipo, 'path', em.url_arquivo)) FROM evidencias_midia em WHERE em.visita_id = v.id),
          '[]'::jsonb
        )
      )
    )
    ORDER BY v.atualizado_em DESC
  ), '[]'::jsonb)
  FROM visitas v
  LEFT JOIN propriedades p ON p.id = v.propriedade_id
  LEFT JOIN especialistas esp ON esp.id = v.especialista_id
  LEFT JOIN floresta_atual fa ON fa.visita_id = v.id
  LEFT JOIN potencial_futuro pf ON pf.visita_id = v.id
  LEFT JOIN logistica lg ON lg.visita_id = v.id
  LEFT JOIN ambiental am ON am.visita_id = v.id
  LEFT JOIN pontuacao pt ON pt.visita_id = v.id
  LEFT JOIN geolocalizacao_visita gv ON gv.visita_id = v.id;
$$;

GRANT EXECUTE ON FUNCTION listar_visitas() TO anon;
GRANT EXECUTE ON FUNCTION listar_visitas() TO authenticated;
