-- Testes da carga incremental. Rodar num banco vazio, depois dos scripts de sql/:
--   psql -v ON_ERROR_STOP=1 -f sql/01_esquema.sql -f sql/02_carga_incremental.sql -f sql/03_visoes.sql -f testes/teste_carga.sql
-- Qualquer ASSERT que falhar interrompe o script com erro.

-- Lote 1: pedidos de janeiro e fevereiro.
INSERT INTO staging.pedidos_itens VALUES
 (1, 1, '2026-01-10 10:00-03', 100, 'Ana', 'Belo Horizonte', 'MG', 'SKU1', 'Caneca', 'Cozinha', 2, 30, 0, '2026-01-10 10:00-03'),
 (1, 2, '2026-01-10 10:00-03', 100, 'Ana', 'Belo Horizonte', 'MG', 'SKU2', 'Toalha', 'Banho',   1, 50, 5, '2026-01-10 10:00-03'),
 (2, 1, '2026-02-03 15:00-03', 200, 'Bia', 'Rio de Janeiro', 'RJ', 'SKU1', 'Caneca', 'Cozinha', 1, 30, 0, '2026-02-03 15:00-03');

DO $$ BEGIN
    ASSERT dw.carregar_vendas() = 3, 'a primeira carga deveria trazer 3 itens';
    ASSERT dw.carregar_vendas() = 0, 'rodar de novo sem novidade não pode carregar nada';
    ASSERT (SELECT count(*) FROM dw.fato_vendas) = 3, 'o fato deveria ter 3 itens';
    ASSERT (SELECT count(*) FROM pg_inherits WHERE inhparent = 'dw.fato_vendas'::regclass) = 2,
           'deveria existir uma partição para janeiro e outra para fevereiro';
END $$;

-- Lote 2: o SKU1 muda de categoria em março, e um item de janeiro é corrigido.
INSERT INTO staging.pedidos_itens VALUES
 (3, 1, '2026-03-05 09:00-03', 100, 'Ana', 'Belo Horizonte', 'MG', 'SKU1', 'Caneca', 'Mesa posta', 4, 30, 0, '2026-03-05 09:00-03')
ON CONFLICT DO NOTHING;
UPDATE staging.pedidos_itens
   SET quantidade = 3, categoria = 'Mesa posta', atualizado_em = '2026-03-06 09:00-03'
 WHERE pedido_id = 1 AND item = 1;

DO $$ BEGIN
    ASSERT dw.carregar_vendas() = 2, 'a segunda carga deveria trazer só os 2 itens que mudaram';
    ASSERT (SELECT count(*) FROM dw.fato_vendas) = 4, 'a correção não pode duplicar o item de janeiro';
    ASSERT (SELECT quantidade FROM dw.fato_vendas WHERE pedido_id = 1 AND item = 1) = 3,
           'a correção da quantidade deveria ter sido aplicada';
    ASSERT (SELECT count(*) FROM dw.dim_produto WHERE sku = 'SKU1') = 2, 'o SKU1 deveria ter duas versões';
    ASSERT (SELECT count(*) FROM dw.dim_produto WHERE sku = 'SKU1' AND atual) = 1, 'só uma versão pode ser a atual';
    ASSERT (SELECT p.categoria FROM dw.fato_vendas f JOIN dw.dim_produto p USING (produto_sk)
             WHERE f.pedido_id = 3) = 'Mesa posta', 'o pedido de março usa a categoria nova';
    ASSERT (SELECT p.categoria FROM dw.fato_vendas f JOIN dw.dim_produto p USING (produto_sk)
             WHERE f.pedido_id = 1 AND f.item = 1) = 'Cozinha', 'o pedido de janeiro mantém a categoria da época';
END $$;

-- Visões materializadas.
SELECT dw.atualizar_visoes();

DO $$ BEGIN
    ASSERT (SELECT receita FROM dw.vendas_mensais_categoria WHERE ano = 2026 AND mes = 3 AND categoria = 'Mesa posta') = 120,
           'receita de março em Mesa posta deveria ser 120';
    ASSERT (SELECT ticket_medio FROM dw.vendas_por_uf WHERE ano = 2026 AND uf = 'MG') = 127.50,
           'ticket médio de MG deveria ser 127,50 (255 em 2 pedidos)';
    RAISE NOTICE 'todos os testes passaram';
END $$;
