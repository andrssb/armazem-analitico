-- Armazém Analítico: esquema dimensional (estrela) de vendas.
-- staging  = cópia crua do sistema de origem, recarregada a cada lote
-- dw       = dimensões e fato, consultadas pelos relatórios

CREATE SCHEMA staging;
CREATE SCHEMA dw;

-- Dados como chegam da origem (pedidos do e-commerce).
CREATE TABLE staging.pedidos_itens (
    pedido_id       BIGINT        NOT NULL,
    item            INT           NOT NULL,
    data_pedido     TIMESTAMPTZ   NOT NULL,
    cliente_id      BIGINT        NOT NULL,
    cliente_nome    VARCHAR(120)  NOT NULL,
    cliente_cidade  VARCHAR(80)   NOT NULL,
    cliente_uf      CHAR(2)       NOT NULL,
    produto_sku     VARCHAR(40)   NOT NULL,
    produto_nome    VARCHAR(160)  NOT NULL,
    categoria       VARCHAR(80)   NOT NULL,
    quantidade      INT           NOT NULL,
    preco_unitario  NUMERIC(12,2) NOT NULL,
    desconto        NUMERIC(12,2) NOT NULL DEFAULT 0,
    atualizado_em   TIMESTAMPTZ   NOT NULL,
    PRIMARY KEY (pedido_id, item)
);

-- Calendário: uma linha por dia. Evita funções de data nas consultas.
CREATE TABLE dw.dim_data (
    data_sk     INT PRIMARY KEY, -- AAAAMMDD
    data        DATE     NOT NULL UNIQUE,
    ano         SMALLINT NOT NULL,
    trimestre   SMALLINT NOT NULL,
    mes         SMALLINT NOT NULL,
    nome_mes    VARCHAR(12) NOT NULL,
    dia_semana  SMALLINT NOT NULL, -- 1 = segunda
    fim_de_semana BOOLEAN NOT NULL
);

-- Produto com histórico (SCD tipo 2): mudou categoria ou nome, nasce uma versão nova
-- e as vendas antigas continuam apontando para a versão da época.
CREATE TABLE dw.dim_produto (
    produto_sk    BIGSERIAL PRIMARY KEY,
    sku           VARCHAR(40)  NOT NULL,
    nome          VARCHAR(160) NOT NULL,
    categoria     VARCHAR(80)  NOT NULL,
    valido_de     TIMESTAMPTZ  NOT NULL,
    valido_ate    TIMESTAMPTZ,
    atual         BOOLEAN      NOT NULL DEFAULT TRUE
);
CREATE UNIQUE INDEX dim_produto_uma_versao_atual ON dw.dim_produto (sku) WHERE atual;

-- Cliente sem histórico (SCD tipo 1): a mudança sobrescreve.
CREATE TABLE dw.dim_cliente (
    cliente_sk  BIGSERIAL PRIMARY KEY,
    cliente_id  BIGINT       NOT NULL UNIQUE,
    nome        VARCHAR(120) NOT NULL,
    cidade      VARCHAR(80)  NOT NULL,
    uf          CHAR(2)      NOT NULL
);

-- Fato no grão de item de pedido, particionado por mês: consultas de um período
-- só leem as partições daquele período, e meses antigos podem ser arquivados.
CREATE TABLE dw.fato_vendas (
    pedido_id     BIGINT        NOT NULL,
    item          INT           NOT NULL,
    data_pedido   DATE          NOT NULL,
    data_sk       INT           NOT NULL REFERENCES dw.dim_data (data_sk),
    produto_sk    BIGINT        NOT NULL REFERENCES dw.dim_produto (produto_sk),
    cliente_sk    BIGINT        NOT NULL REFERENCES dw.dim_cliente (cliente_sk),
    quantidade    INT           NOT NULL,
    receita_bruta NUMERIC(14,2) NOT NULL,
    desconto      NUMERIC(14,2) NOT NULL,
    receita_liquida NUMERIC(14,2) GENERATED ALWAYS AS (receita_bruta - desconto) STORED,
    PRIMARY KEY (pedido_id, item, data_pedido)
) PARTITION BY RANGE (data_pedido);

CREATE INDEX fato_vendas_produto ON dw.fato_vendas (produto_sk);
CREATE INDEX fato_vendas_cliente ON dw.fato_vendas (cliente_sk);

-- Controle da carga incremental: até onde a origem já foi lida.
CREATE TABLE dw.controle_carga (
    tabela         VARCHAR(60) PRIMARY KEY,
    lido_ate       TIMESTAMPTZ NOT NULL,
    executado_em   TIMESTAMPTZ NOT NULL DEFAULT now(),
    linhas         BIGINT      NOT NULL DEFAULT 0
);
INSERT INTO dw.controle_carga (tabela, lido_ate) VALUES ('fato_vendas', '-infinity');
