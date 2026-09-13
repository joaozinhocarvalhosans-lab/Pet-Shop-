-- ============================================================
-- PetGestor — Correções de segurança e integridade
-- Segunda migration, aplicada em cima de 20250913000000.
-- Cobre os pontos levantados na revisão do schema:
--   1) GRANT de colunas em petshops não restringia nada de fato
--   2) cliente autenticado perdia acesso ao próprio petshop
--   3) faltavam FKs de tenant em hospedagens/prontuarios/registros_ponto
--   4) não existia forma de um cliente se autocadastrar
--   5) modulos_ativos só podia ser escrito via service_role
--   6) trigger de trava de tenant sem search_path fixo
--   7) faltavam índices nas colunas usadas pelas políticas de RLS
--   8) faltavam checks de integridade (status, valores não negativos)
--   9) pedidos.total era um valor livre vindo do cliente (sem base
--      em itens/preço real) — abre para manipulação de preço
-- ============================================================

-- ============================================================
-- PARTE 12 — Corrige a exposição pública de petshops
-- ============================================================

revoke select on petshops from anon;
grant select (id, nome, slug, logo_url) on petshops to anon;

-- ============================================================
-- PARTE 13 — Cliente autenticado precisa ver o proprio petshop
-- (a policy "to anon" da migration anterior não cobre usuários logados)
-- ============================================================

create policy "Cliente autenticado ve o proprio petshop"
on petshops
for select
to authenticated
using (private.eh_cliente_do_petshop(id));

-- ============================================================
-- PARTE 14 — Uniques necessários para as novas FKs de tenant
-- ============================================================

alter table funcionarios add constraint funcionarios_id_petshop_unique unique (id, petshop_id);
alter table pedidos add constraint pedidos_id_petshop_unique unique (id, petshop_id);
alter table produtos add constraint produtos_id_petshop_unique unique (id, petshop_id);

-- ============================================================
-- PARTE 15 — FKs de tenant que faltavam
-- Sem isso, um funcionário do petshop A conseguia gravar uma
-- hospedagem/prontuário apontando pra um pet do petshop B (mesma
-- lógica para registros_ponto e um funcionário de outra loja).
-- ============================================================

alter table hospedagens
  add constraint hospedagens_pet_mesmo_tenant
  foreign key (pet_id, petshop_id) references pets (id, petshop_id);

alter table prontuarios
  add constraint prontuarios_pet_mesmo_tenant
  foreign key (pet_id, petshop_id) references pets (id, petshop_id);

alter table registros_ponto
  add constraint registros_ponto_funcionario_mesmo_tenant
  foreign key (funcionario_id, petshop_id) references funcionarios (id, petshop_id);

-- ============================================================
-- PARTE 16 — Autocadastro do cliente final
-- ============================================================

create policy "Usuario autenticado cria o proprio cadastro de cliente"
on clientes
for insert
to authenticated
with check (
  auth_user_id = auth.uid()
  and private.petshop_ativo(petshop_id)
);

-- ============================================================
-- PARTE 17 — Dono ativa/desativa módulos do proprio petshop
-- ============================================================

create policy "Dono ativa modulos do proprio petshop"
on modulos_ativos for insert
with check (
  petshop_id = private.petshop_id()
  and private.acesso_liberado()
  and exists (
    select 1 from usuarios_admin
    where id = auth.uid() and cargo = 'dono'
  )
);

create policy "Dono atualiza modulos do proprio petshop"
on modulos_ativos for update
using (
  petshop_id = private.petshop_id()
  and private.acesso_liberado()
  and exists (
    select 1 from usuarios_admin
    where id = auth.uid() and cargo = 'dono'
  )
);

-- ============================================================
-- PARTE 18 — Hardening da função de trava de tenant
-- ============================================================

create or replace function private.travar_colunas_tenant()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.petshop_id is distinct from old.petshop_id
     or new.auth_user_id is distinct from old.auth_user_id then
    raise exception 'Não é permitido alterar petshop_id ou auth_user_id';
  end if;
  return new;
end;
$$;

-- ============================================================
-- PARTE 19 — Índices nas colunas usadas pelas políticas de RLS
-- ============================================================

create index if not exists idx_usuarios_admin_petshop_id on usuarios_admin(petshop_id);
create index if not exists idx_pets_petshop_id on pets(petshop_id);
create index if not exists idx_pets_cliente_id on pets(cliente_id);
create index if not exists idx_agendamentos_petshop_id on agendamentos(petshop_id);
create index if not exists idx_agendamentos_pet_id on agendamentos(pet_id);
create index if not exists idx_produtos_petshop_id on produtos(petshop_id);
create index if not exists idx_pedidos_petshop_id on pedidos(petshop_id);
create index if not exists idx_pedidos_cliente_id on pedidos(cliente_id);
create index if not exists idx_funcionarios_petshop_id on funcionarios(petshop_id);
create index if not exists idx_hospedagens_petshop_id on hospedagens(petshop_id);
create index if not exists idx_hospedagens_pet_id on hospedagens(pet_id);
create index if not exists idx_prontuarios_petshop_id on prontuarios(petshop_id);
create index if not exists idx_prontuarios_pet_id on prontuarios(pet_id);
create index if not exists idx_registros_ponto_petshop_id on registros_ponto(petshop_id);
create index if not exists idx_registros_ponto_funcionario_id on registros_ponto(funcionario_id);

-- ============================================================
-- PARTE 20 — Checks de integridade
-- ============================================================

alter table agendamentos
  add constraint agendamentos_status_valido
  check (status in ('pendente', 'confirmado', 'em_andamento', 'concluido', 'cancelado'));

alter table pedidos
  add constraint pedidos_status_valido
  check (status in ('novo', 'preparando', 'pronto', 'entregue', 'cancelado'));

alter table pedidos
  add constraint pedidos_total_nao_negativo
  check (total >= 0);

alter table hospedagens
  add constraint hospedagens_status_valido
  check (status in ('reservado', 'em_andamento', 'concluido', 'cancelado'));

alter table produtos
  add constraint produtos_preco_nao_negativo
  check (preco >= 0);

alter table produtos
  add constraint produtos_estoque_nao_negativo
  check (estoque >= 0);

-- ============================================================
-- PARTE 21 — Itens de pedido + total calculado no servidor
-- Antes, "total" vinha direto do cliente, sem relação com produtos/
-- preços reais. Agora o total só existe a partir dos itens, e o
-- preço de cada item vem sempre do catálogo (produtos.preco), nunca
-- do que o cliente mandar no insert.
-- ============================================================

create table pedido_itens (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  pedido_id uuid not null references pedidos(id) on delete cascade,
  produto_id uuid not null references produtos(id),
  quantidade integer not null check (quantidade > 0),
  preco_unitario numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);

alter table pedido_itens
  add constraint pedido_itens_pedido_mesmo_tenant
  foreign key (pedido_id, petshop_id) references pedidos (id, petshop_id);

alter table pedido_itens
  add constraint pedido_itens_produto_mesmo_tenant
  foreign key (produto_id, petshop_id) references produtos (id, petshop_id);

create index if not exists idx_pedido_itens_petshop_id on pedido_itens(petshop_id);
create index if not exists idx_pedido_itens_pedido_id on pedido_itens(pedido_id);

alter table pedido_itens enable row level security;

create policy "Staff ve itens de pedidos do seu petshop"
on pedido_itens for select
using (petshop_id = private.petshop_id());

create policy "Staff insere itens de pedidos com acesso liberado"
on pedido_itens for insert
with check (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff atualiza itens de pedidos com acesso liberado"
on pedido_itens for update
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff apaga itens de pedidos com acesso liberado"
on pedido_itens for delete
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Cliente ve itens dos proprios pedidos"
on pedido_itens for select
using (
  exists (
    select 1 from pedidos
    where pedidos.id = pedido_itens.pedido_id
      and private.eh_meu_cliente_id(pedidos.cliente_id)
  )
);

create policy "Cliente adiciona itens ao proprio pedido"
on pedido_itens for insert
with check (
  private.eh_cliente_do_petshop(petshop_id)
  and private.petshop_ativo(petshop_id)
  and exists (
    select 1 from pedidos
    where pedidos.id = pedido_itens.pedido_id
      and private.eh_meu_cliente_id(pedidos.cliente_id)
  )
);

-- Preço do item sempre vem do catálogo, nunca do payload do cliente.
create or replace function private.definir_preco_item_pedido()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  select preco into new.preco_unitario
  from produtos
  where id = new.produto_id;
  return new;
end;
$$;

create trigger pedido_itens_define_preco
before insert on pedido_itens
for each row execute function private.definir_preco_item_pedido();

-- Total do pedido é recalculado a partir dos itens.
create or replace function private.recalcular_total_pedido()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  alvo_pedido uuid;
begin
  alvo_pedido := coalesce(new.pedido_id, old.pedido_id);

  update pedidos
    set total = (
      select coalesce(sum(quantidade * preco_unitario), 0)
      from pedido_itens
      where pedido_id = alvo_pedido
    )
    where id = alvo_pedido;

  return null;
end;
$$;

create trigger pedido_itens_recalcula_total
after insert or update or delete on pedido_itens
for each row execute function private.recalcular_total_pedido();

-- Cliente final não pode chutar um total no insert do pedido — staff
-- (venda balcão, por exemplo) continua podendo informar um total
-- manual, já que não está sujeito a esse risco de manipulação externa.
create or replace function private.forcar_total_inicial_pedido()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from usuarios_admin where id = auth.uid()) then
    new.total := 0;
  end if;
  return new;
end;
$$;

create trigger pedidos_forca_total_inicial
before insert on pedidos
for each row execute function private.forcar_total_inicial_pedido();

-- ============================================================
-- FIM das correções.
-- ============================================================
