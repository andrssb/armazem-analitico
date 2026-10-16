-- Visões materializadas: os relatórios leem o resultado pronto em vez de agregar o fato
-- inteiro a cada consulta. São atualizadas depois de cada carga.

CREATE MATERIALIZED VIEW dw.vendas_mensais_categoria AS
SELECT d.ano, d.mes, p.categoria,
       count(DISTINCT f.pedido_id) AS pedidos,
       sum(f.quantidade)           AS itens,
       sum(f.receita_liquida)      AS receita
FROM dw.fato_vendas f
JOIN dw.dim_data d    ON d.data_sk = f.data_sk
JOIN dw.dim_produto p ON p.produto_sk = f.produto_sk
GROUP BY d.ano, d.mes, p.categoria;

CREATE UNIQUE INDEX vendas_mensais_categoria_chave ON dw.vendas_mensais_categoria (ano, mes, categoria);

CREATE MATERIALIZED VIEW dw.vendas_por_uf AS
SELECT d.ano, c.uf,
       count(DISTINCT f.cliente_sk) AS clientes,
       sum(f.receita_liquida)       AS receita,
       sum(f.receita_liquida) / NULLIF(count(DISTINCT f.pedido_id), 0) AS ticket_medio
FROM dw.fato_vendas f
JOIN dw.dim_data d    ON d.data_sk = f.data_sk
JOIN dw.dim_cliente c ON c.cliente_sk = f.cliente_sk
GROUP BY d.ano, c.uf;

CREATE UNIQUE INDEX vendas_por_uf_chave ON dw.vendas_por_uf (ano, uf);

-- O índice único permite atualizar com CONCURRENTLY, sem bloquear quem está lendo.
CREATE FUNCTION dw.atualizar_visoes() RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY dw.vendas_mensais_categoria;
    REFRESH MATERIALIZED VIEW CONCURRENTLY dw.vendas_por_uf;
END;
$$ LANGUAGE plpgsql;
