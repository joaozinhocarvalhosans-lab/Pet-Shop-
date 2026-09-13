# PetGestor

Banco de dados (Postgres/Supabase) de um SaaS multi-tenant para petshops:
agendamentos, clientes, pets, produtos, pedidos, funcionários, e os módulos
opcionais de hotel (hospedagens), veterinário (prontuários) e controle de
ponto.

Este repositório contém só o **schema do banco** (migrations SQL). O
frontend é construído à parte (ex: Lovable) conectado a este Supabase via
`anon key` — toda a segurança de isolamento entre petshops é garantida pelo
banco (Row Level Security), não pela aplicação.

## Modelo de dados

- **Multi-tenant por linha**: cada tabela do domínio tem uma coluna
  `petshop_id`, e o RLS filtra tudo por ela. Não existe schema por cliente.
- **Dois tipos de usuário**:
  - `usuarios_admin` — staff do petshop (`dono`, `gerente`, `atendente`),
    ligado 1:1 a um `auth.users`.
  - `clientes` — cliente final (dono do pet), ligado a um `auth.users` e a
    um `petshop_id`. O mesmo e-mail pode ser cliente de vários petshops
    (uma linha em `clientes` por petshop).
- **Ciclo de vida do petshop** (`petshops.status`): `trial` (com
  `trial_expira_em`), `ativo`, `inadimplente`, `cancelado`. Trial vencido ou
  petshop não-ativo bloqueia toda escrita nas tabelas do domínio — isso é
  garantido a nível de banco pela função `private.acesso_liberado()`, usada
  nas policies de `insert`/`update`/`delete`.
- **Módulos opcionais** (`modulos_ativos`: `hotel`, `veterinario`, `ponto`):
  controlam se `hospedagens`, `prontuarios` e `registros_ponto` ficam
  visíveis/graváveis para aquele petshop. Só o `dono` ativa/desativa.
- **Pedidos**: o total nunca é um valor livre vindo do cliente. Itens ficam
  em `pedido_itens`, o preço de cada item é copiado do catálogo
  (`produtos.preco`) no momento do insert, e `pedidos.total` é recalculado
  por trigger a partir da soma dos itens.

## Estrutura

```
supabase/
  migrations/
    20250913000000_petgestor_schema_seguranca.sql   # schema base + RLS
    20250913010000_petgestor_correcoes_seguranca.sql # correções de segurança/integridade
```

As migrations devem ser aplicadas **nessa ordem**. A segunda depende de
objetos criados na primeira.

## Como aplicar

Com a [Supabase CLI](https://supabase.com/docs/guides/cli) apontando pro
projeto:

```bash
supabase link --project-ref <seu-project-ref>
supabase db push
```

Ou, direto pelo SQL Editor do painel do Supabase: rode os arquivos de
`supabase/migrations/` na ordem, de cima pra baixo.

## Segurança (resumo)

- Toda tabela do domínio tem RLS habilitado; não existe acesso via papel
  `anon`/`authenticated` sem passar por policy.
- Funções auxiliares em `private.*` (schema não exposto via API) resolvem
  "qual o meu petshop", "esse petshop está ativo", "esse é meu cliente" etc,
  todas `security definer` com `search_path` fixo.
- Constraints de FK compostas (`(id, petshop_id)`) impedem que um registro
  de uma tabela filha aponte para um registro "pai" de outro petshop —
  fecha o caso em que RLS sozinha não bastaria (ex.: staff referenciando um
  pet de outra loja).
- `leads_interesse` (formulário público do site) só aceita `insert` de
  `anon`; leitura é só via `service_role` (painel interno).
- Colunas públicas de `petshops` (para resolver a página pública pelo
  slug) são expostas via `grant select (id, nome, slug, logo_url)` — o
  `select` amplo é revogado do papel `anon` antes disso, então dados como
  `cnpj` e `trial_expira_em` não vazam.

## Frontend

Nenhum frontend está neste repositório. Ao conectar uma ferramenta (ex.
Lovable) ou uma aplicação própria a este banco:

- Use sempre a `anon key` do lado do cliente — nunca a `service_role key`.
- Não reimplemente checagem de `petshop_id` na aplicação como camada de
  segurança; ela já existe no banco. A aplicação só precisa filtrar/enviar
  os dados certos e tratar erros de permissão.
- Não deixe a UI enviar/editar `pedidos.total` ou `pedido_itens.preco_unitario`
  diretamente — esses valores são calculados pelo banco.
