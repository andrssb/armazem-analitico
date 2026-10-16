# Armazém Analítico

Data warehouse de vendas em modelo dimensional no PostgreSQL. A ideia é separar o banco que registra as vendas do banco que responde perguntas sobre elas: "quanto cada categoria vendeu por mês", "qual o ticket médio por estado", sem pesar no sistema de origem e sem refazer a soma de milhões de linhas a cada relatório.

> **Status:** em andamento. O esquema, a carga incremental, as visões materializadas e os testes da carga estão prontos. Faltam o gerador de volume, os modelos em dbt e a medição de desempenho.

## Como está organizado

```
sistema de origem ──extração──> staging.pedidos_itens
                                      │
                      dw.carregar_vendas()  (só o que mudou desde a última carga)
                                      │
            ┌─────────────┬───────────┴───────────┬──────────────┐
       dim_data      dim_produto (SCD 2)     dim_cliente (SCD 1)   fato_vendas (particionado por mês)
                                      │
                    visões materializadas para os relatórios
```

**Modelo estrela.** O fato `fato_vendas` tem uma linha por item de pedido (o grão) e aponta para as dimensões de data, produto e cliente. Relatório vira junção simples e agregação, sem regra de negócio espalhada nas consultas.

**Histórico do produto (SCD tipo 2).** Quando um produto muda de nome ou de categoria, a versão antiga é fechada e nasce uma nova. Cada venda aponta para a versão que valia na data do pedido, então o relatório de janeiro continua mostrando a categoria de janeiro mesmo depois da mudança. O cliente usa SCD tipo 1: a mudança sobrescreve, porque o histórico de endereço não interessa aqui.

**Carga incremental e idempotente.** `dw.controle_carga` guarda até onde a origem já foi lida. A carga pega só as linhas com `atualizado_em` posterior a essa marca e grava com upsert pela chave natural. Rodar de novo sem novidade não carrega nada, e uma correção na origem atualiza o item em vez de duplicar.

**Particionamento por mês.** `fato_vendas` é particionada por `data_pedido`. A carga cria a partição do mês quando ela ainda não existe. Consulta de um período lê só as partições daquele período, e meses antigos podem ser desanexados e arquivados sem `DELETE`.

**Visões materializadas.** `vendas_mensais_categoria` e `vendas_por_uf` guardam o resultado já agregado. Elas têm índice único, o que permite `REFRESH ... CONCURRENTLY`: a atualização roda sem bloquear quem está consultando.

## Arquivos

| Arquivo | O que tem |
|---|---|
| [`sql/01_esquema.sql`](sql/01_esquema.sql) | Staging, dimensões, fato particionado e controle de carga |
| [`sql/02_carga_incremental.sql`](sql/02_carga_incremental.sql) | Carga incremental, SCD 2 do produto, calendário e partições |
| [`sql/03_visoes.sql`](sql/03_visoes.sql) | Visões materializadas e a função que atualiza as duas |
| [`testes/teste_carga.sql`](testes/teste_carga.sql) | Testes da carga com `ASSERT` |

## Como rodar

Num banco PostgreSQL 16 vazio:

```bash
psql -v ON_ERROR_STOP=1 \
  -f sql/01_esquema.sql \
  -f sql/02_carga_incremental.sql \
  -f sql/03_visoes.sql \
  -f testes/teste_carga.sql
```

O teste carrega dois lotes e confere que a carga repetida não duplica, que a correção de um item é aplicada, que o produto ganha uma segunda versão, que cada pedido usa a categoria da sua época, que as partições de cada mês foram criadas e que as visões trazem os totais certos.

## Etapas

- [x] Modelo dimensional (estrela) com dimensões de data, produto e cliente
- [x] Fato particionado por mês com criação automática de partição
- [x] Carga incremental idempotente com SCD tipo 2 no produto
- [x] Visões materializadas com atualização concorrente
- [x] Testes da carga
- [ ] Gerador de dados em Python para simular 10 milhões de itens de pedido
- [ ] Modelos em dbt para as camadas de staging e de marts, com testes de qualidade
- [ ] Comparação de desempenho com `EXPLAIN ANALYZE`: tabela única x particionada x visão materializada
- [ ] Docker Compose para subir o banco e rodar tudo com um comando
