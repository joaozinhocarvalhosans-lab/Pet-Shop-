-- ============================================================
-- PetGestor — Correções pós-auditoria de segurança
-- Terceira migration, aplicada em cima de 20250913010000.
-- Cobre:
--   1) [CRÍTICO] forcar_total_inicial_pedido() checava "é staff em
--      ALGUM petshop", não "é staff DESTE petshop" — um usuário que
--      fosse staff no seu próprio petshop conseguia se autocadastrar
--      como cliente de OUTRO petshop e inserir um pedido com total
--      arbitrário (sem itens, então o trigger que recalcula o total
--      a partir de pedido_itens nunca corrigia o valor).
--   2) [MÉDIO] petshops: authenticated (inclusive cliente final) lia
--      cnpj, plano_id e trial_expira_em do próprio petshop sem
--      necessidade, porque só o papel anon tinha restrição de coluna.
--   3) [MÉDIO] usuarios_admin: qualquer colega (inclusive atendente)
--      lia cpf e telefone de todo funcionário do mesmo petshop,
--      porque a policy de select para colegas não distinguia coluna
--      nem cargo.
-- ============================================================

-- ============================================================
-- PARTE 22 — Corrige o escopo de tenant em forcar_total_inicial_pedido
-- Antes: "existe uma linha em usuarios_admin para este auth.uid()?"
-- (verdade em qualquer petshop). Agora: "esse auth.uid() é staff
-- justamente do petshop deste pedido?" — reaproveita private.petshop_id(),
-- que já é a função central usada em todo o resto do schema.
-- ============================================================

create or replace function private.forcar_total_inicial_pedido()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if private.petshop_id() is distinct from new.petshop_id then
    new.total := 0;
  end if;
  return new;
end;
$$;

-- ============================================================
-- PARTE 23 — petshops: authenticated só vê colunas públicas na
-- tabela base (mesmo conjunto já liberado pra anon). Os campos
-- administrativos do próprio petshop (cnpj, plano_id,
-- trial_expira_em, cidade, estado) passam a ser lidos pela view
-- meu_petshop, que só devolve linha pra quem é staff daquele
-- petshop (private.petshop_id() = id) — cliente final não vê nada
-- nela, mesmo sendo authenticated.
--
-- Frontend: telas de staff que hoje leem cnpj/plano_id/trial_expira_em
-- direto de "petshops" precisam passar a consultar "meu_petshop".
-- ============================================================

revoke select on petshops from authenticated;
grant select (id, nome, slug, logo_url, status, created_at) on petshops to authenticated;

create or replace view public.meu_petshop as
select
  id, nome, slug, logo_url, status, created_at,
  cnpj, plano_id, trial_expira_em, cidade, estado
from petshops
where id = private.petshop_id();

grant select on public.meu_petshop to authenticated;

-- ============================================================
-- PARTE 24 — usuarios_admin: cpf e telefone deixam de vir na
-- tabela base para qualquer colega. Colunas de contato de trabalho
-- (nome, cargo, email) continuam visíveis entre colegas do mesmo
-- petshop, como antes.
--
-- Cada staff continua vendo o próprio cpf/telefone via
-- meu_perfil_admin. Dono/gerente continuam vendo cpf/telefone da
-- equipe via equipe_admin_pii (necessário pra folha de pagamento e
-- gestão de RH) — atendente não vê nada nessa view.
--
-- Frontend: telas que hoje leem cpf/telefone de colegas direto de
-- "usuarios_admin" precisam passar a consultar "meu_perfil_admin"
-- (próprio perfil) ou "equipe_admin_pii" (dono/gerente).
-- ============================================================

revoke select on usuarios_admin from authenticated;
grant select (id, petshop_id, nome, cargo, email) on usuarios_admin to authenticated;

create or replace view public.meu_perfil_admin as
select id, petshop_id, nome, cargo, email, cpf, telefone
from usuarios_admin
where id = auth.uid();

grant select on public.meu_perfil_admin to authenticated;

create or replace view public.equipe_admin_pii as
select ua.id, ua.petshop_id, ua.nome, ua.cargo, ua.email, ua.cpf, ua.telefone
from usuarios_admin ua
where ua.petshop_id = private.petshop_id()
  and exists (
    select 1 from usuarios_admin dono_ou_gerente
    where dono_ou_gerente.id = auth.uid()
      and dono_ou_gerente.cargo in ('dono', 'gerente')
  );

grant select on public.equipe_admin_pii to authenticated;

-- ============================================================
-- FIM das correções pós-auditoria.
-- ============================================================
