-- Carga incremental: lê só o que mudou na origem desde a última execução
-- e pode rodar de novo sem duplicar nada (upsert pela chave natural).

-- Cria a partição mensal que ainda não existe.
CREATE FUNCTION dw.garante_particao(mes DATE) RETURNS void AS $$
DECLARE
    inicio DATE := date_trunc('month', mes);
    nome   TEXT := 'fato_vendas_' || to_char(inicio, 'YYYY_MM');
BEGIN
    IF to_regclass('dw.' || nome) IS NULL THEN
        EXECUTE format('CREATE TABLE dw.%I PARTITION OF dw.fato_vendas FOR VALUES FROM (%L) TO (%L)',
                       nome, inicio, inicio + INTERVAL '1 month');
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Preenche o calendário entre duas datas.
CREATE FUNCTION dw.garante_datas(de DATE, ate DATE) RETURNS void AS $$
    INSERT INTO dw.dim_data
    SELECT to_char(d, 'YYYYMMDD')::INT, d, extract(year FROM d), extract(quarter FROM d), extract(month FROM d),
           (ARRAY['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'])[extract(month FROM d)],
           extract(isodow FROM d), extract(isodow FROM d) IN (6, 7)
    FROM generate_series(de, ate, INTERVAL '1 day') AS g(d)
    ON CONFLICT (data) DO NOTHING;
$$ LANGUAGE sql;

CREATE FUNCTION dw.carregar_vendas() RETURNS BIGINT AS $$
DECLARE
    desde  TIMESTAMPTZ;
    ate    TIMESTAMPTZ;
    total  BIGINT;
    m      DATE;
BEGIN
    SELECT lido_ate INTO desde FROM dw.controle_carga WHERE tabela = 'fato_vendas' FOR UPDATE;
    SELECT max(atualizado_em) INTO ate FROM staging.pedidos_itens WHERE atualizado_em > desde;
    IF ate IS NULL THEN
        RETURN 0; -- nada novo
    END IF;

    -- Se a carga rodar duas vezes na mesma transação, as tabelas temporárias da anterior ainda existem.
    DROP TABLE IF EXISTS lote, produtos_lote;
    CREATE TEMP TABLE lote ON COMMIT DROP AS
        SELECT * FROM staging.pedidos_itens WHERE atualizado_em > desde AND atualizado_em <= ate;

    PERFORM dw.garante_datas(min(data_pedido)::DATE, max(data_pedido)::DATE) FROM lote;
    FOR m IN SELECT DISTINCT date_trunc('month', data_pedido)::DATE FROM lote LOOP
        PERFORM dw.garante_particao(m);
    END LOOP;

    -- Cliente: SCD tipo 1.
    INSERT INTO dw.dim_cliente (cliente_id, nome, cidade, uf)
    SELECT DISTINCT ON (cliente_id) cliente_id, cliente_nome, cliente_cidade, cliente_uf
    FROM lote ORDER BY cliente_id, atualizado_em DESC
    ON CONFLICT (cliente_id) DO UPDATE SET nome = EXCLUDED.nome, cidade = EXCLUDED.cidade, uf = EXCLUDED.uf;

    -- Produto: SCD tipo 2. Fecha a versão atual que mudou e abre uma nova.
    -- Estado mais recente de cada produto no lote. A versão nova vale desde a primeira
    -- vez que esse estado apareceu, não desde a última atualização do lote.
    CREATE TEMP TABLE produtos_lote ON COMMIT DROP AS
        SELECT u.sku, u.nome, u.categoria,
               (SELECT min(l.atualizado_em) FROM lote l
                WHERE l.produto_sku = u.sku AND l.produto_nome = u.nome AND l.categoria = u.categoria) AS atualizado_em
        FROM (SELECT DISTINCT ON (produto_sku) produto_sku AS sku, produto_nome AS nome, categoria
              FROM lote ORDER BY produto_sku, atualizado_em DESC) u;

    UPDATE dw.dim_produto p SET valido_ate = n.atualizado_em, atual = FALSE
    FROM produtos_lote n
    WHERE p.sku = n.sku AND p.atual AND (p.nome, p.categoria) IS DISTINCT FROM (n.nome, n.categoria);

    INSERT INTO dw.dim_produto (sku, nome, categoria, valido_de)
    SELECT n.sku, n.nome, n.categoria, n.atualizado_em
    FROM produtos_lote n
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_produto p WHERE p.sku = n.sku AND p.atual);

    -- Fato: cada item aponta para a versão do produto vigente na data do pedido.
    INSERT INTO dw.fato_vendas (pedido_id, item, data_pedido, data_sk, produto_sk, cliente_sk, quantidade, receita_bruta, desconto)
    SELECT l.pedido_id, l.item, l.data_pedido::DATE, to_char(l.data_pedido, 'YYYYMMDD')::INT,
           p.produto_sk, c.cliente_sk, l.quantidade, l.quantidade * l.preco_unitario, l.desconto
    FROM lote l
    JOIN dw.dim_cliente c ON c.cliente_id = l.cliente_id
    JOIN LATERAL (
        SELECT produto_sk FROM dw.dim_produto p
        WHERE p.sku = l.produto_sku
        -- a versão mais recente que já valia na data; pedido anterior à primeira versão usa a primeira
        ORDER BY (p.valido_de <= l.data_pedido) DESC,
                 CASE WHEN p.valido_de <= l.data_pedido THEN p.valido_de END DESC,
                 p.valido_de
        LIMIT 1
    ) p ON TRUE
    ON CONFLICT (pedido_id, item, data_pedido) DO UPDATE
        SET produto_sk = EXCLUDED.produto_sk, cliente_sk = EXCLUDED.cliente_sk, quantidade = EXCLUDED.quantidade,
            receita_bruta = EXCLUDED.receita_bruta, desconto = EXCLUDED.desconto;
    GET DIAGNOSTICS total = ROW_COUNT;

    UPDATE dw.controle_carga SET lido_ate = ate, executado_em = now(), linhas = total WHERE tabela = 'fato_vendas';
    RETURN total;
END;
$$ LANGUAGE plpgsql;
