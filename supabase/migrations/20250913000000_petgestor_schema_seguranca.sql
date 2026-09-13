-- ============================================================
-- PetGestor — Script completo pra rodar no SQL Editor do Supabase
-- Execute de cima pra baixo, tudo de uma vez (ou em blocos, na ordem).
-- Baseado em petgestor-schema-seguranca.md
-- ============================================================

-- ============================================================
-- PARTE 0 — Tabelas base
-- (O documento original não tinha os CREATE TABLE completos —
-- completei com colunas básicas e sensatas; ajuste depois se precisar)
-- ============================================================

create table petshops (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  slug text not null unique,
  plano_id text,
  status text not null default 'trial' check (status in ('trial', 'ativo', 'inadimplente', 'cancelado')),
  trial_expira_em timestamptz,
  cnpj text,
  cidade text,
  estado text,
  logo_url text,
  created_at timestamptz not null default now()
);

create table usuarios_admin (
  id uuid primary key references auth.users(id),
  petshop_id uuid not null references petshops(id),
  nome text not null,
  cargo text not null default 'atendente' check (cargo in ('dono', 'gerente', 'atendente')),
  email text,
  cpf text,
  telefone text
);

create table clientes (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid references auth.users(id),
  petshop_id uuid not null references petshops(id),
  nome text not null,
  telefone text,
  email text,
  created_at timestamptz not null default now(),
  unique (auth_user_id, petshop_id)
);

create table pets (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  cliente_id uuid not null references clientes(id),
  nome text not null,
  especie text,
  raca text,
  porte text,
  created_at timestamptz not null default now()
);

create table agendamentos (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  pet_id uuid not null references pets(id),
  servico text not null,
  data_hora timestamptz not null,
  status text not null default 'confirmado',
  created_at timestamptz not null default now()
);

create table produtos (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  nome text not null,
  preco numeric(10,2) not null default 0,
  estoque integer not null default 0
);

create table pedidos (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  cliente_id uuid not null references clientes(id),
  status text not null default 'novo',
  total numeric(10,2) not null default 0,
  created_at timestamptz not null default now()
);

create table funcionarios (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  nome text not null,
  cargo text,
  created_at timestamptz not null default now()
);

create table hospedagens (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  pet_id uuid not null references pets(id),
  check_in date not null,
  check_out date not null,
  status text not null default 'reservado'
);

create table prontuarios (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  pet_id uuid not null references pets(id),
  descricao text not null,
  created_at timestamptz not null default now()
);

create table registros_ponto (
  id uuid primary key default gen_random_uuid(),
  petshop_id uuid not null references petshops(id),
  funcionario_id uuid not null references funcionarios(id),
  tipo text not null check (tipo in ('entrada', 'saida')),
  horario timestamptz not null default now()
);

create table leads_interesse (
  id uuid primary key default gen_random_uuid(),
  nome text,
  petshop_nome text,
  contato text,
  plano text,
  modulos text[],
  trial boolean not null default false,
  created_at timestamptz not null default now()
);

-- ============================================================
-- PARTE 1 — Schema privado + função central de petshop do usuário
-- ============================================================

create schema if not exists private;

create or replace function private.petshop_id()
returns uuid
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select petshop_id from usuarios_admin where id = auth.uid()
$$;

revoke execute on function private.petshop_id() from public;
grant execute on function private.petshop_id() to authenticated;

-- ============================================================
-- PARTE 2 — Travar usuarios_admin
-- ============================================================

alter table usuarios_admin enable row level security;

create policy "Usuario ve o proprio registro"
on usuarios_admin
for select
using (id = auth.uid());

create policy "Staff ve colegas do mesmo petshop"
on usuarios_admin
for select
using (petshop_id = private.petshop_id());

-- Sem policy de insert/update/delete de propósito — só service_role escreve aqui.

-- ============================================================
-- PARTE 3 — Travar petshops
-- ============================================================

alter table petshops enable row level security;

create policy "Usuario ve apenas seu proprio petshop"
on petshops
for select
using (id = private.petshop_id());

-- Sem policy de insert/update/delete de propósito — só service_role escreve aqui.

-- ============================================================
-- PARTE 4 — Bloqueio por teste vencido ou inadimplência (função central)
-- ============================================================

create or replace function private.petshop_ativo(alvo_petshop uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select case
    when p.status = 'ativo' then true
    when p.status = 'trial' then p.trial_expira_em > now()
    else false
  end
  from petshops p
  where p.id = alvo_petshop
$$;

create or replace function private.acesso_liberado()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select private.petshop_ativo(private.petshop_id())
$$;

revoke execute on function private.petshop_ativo(uuid) from public;
revoke execute on function private.acesso_liberado() from public;
grant execute on function private.petshop_ativo(uuid) to authenticated;
grant execute on function private.acesso_liberado() to authenticated;

-- pets (parte staff — a parte do cliente vem na PARTE 6)
alter table pets enable row level security;

create policy "Staff ve pets do seu petshop"
on pets for select
using (petshop_id = private.petshop_id());

create policy "Staff insere pets com acesso liberado"
on pets for insert
with check (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff atualiza pets com acesso liberado"
on pets for update
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff apaga pets com acesso liberado"
on pets for delete
using (petshop_id = private.petshop_id() and private.acesso_liberado());

-- ============================================================
-- PARTE 5 — clientes (staff + próprio cliente) + trava de tenant
-- ============================================================

alter table clientes enable row level security;

create policy "Staff ve clientes do seu petshop"
on clientes
for select
using (petshop_id = private.petshop_id());

create policy "Cliente ve o proprio cadastro"
on clientes
for select
using (auth_user_id = auth.uid());

create policy "Cliente edita o proprio cadastro"
on clientes
for update
using (auth_user_id = auth.uid())
with check (auth_user_id = auth.uid());

create or replace function private.travar_colunas_tenant()
returns trigger
language plpgsql
as $$
begin
  if new.petshop_id is distinct from old.petshop_id
     or new.auth_user_id is distinct from old.auth_user_id then
    raise exception 'Não é permitido alterar petshop_id ou auth_user_id';
  end if;
  return new;
end;
$$;

create trigger clientes_trava_tenant
before update on clientes
for each row execute function private.travar_colunas_tenant();

-- ============================================================
-- PARTE 6 — Acesso do cliente final (produtos, pedidos, agendamentos, pets)
-- ============================================================

create or replace function private.eh_cliente_do_petshop(alvo_petshop uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from clientes
    where auth_user_id = auth.uid() and petshop_id = alvo_petshop
  )
$$;

create or replace function private.eh_meu_cliente_id(alvo_cliente uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from clientes
    where id = alvo_cliente and auth_user_id = auth.uid()
  )
$$;

revoke execute on function private.eh_cliente_do_petshop(uuid) from public;
revoke execute on function private.eh_meu_cliente_id(uuid) from public;
grant execute on function private.eh_cliente_do_petshop(uuid) to authenticated;
grant execute on function private.eh_meu_cliente_id(uuid) to authenticated;

-- produtos
alter table produtos enable row level security;

create policy "Staff ve produtos do seu petshop"
on produtos for select
using (petshop_id = private.petshop_id());

create policy "Staff insere produtos com acesso liberado"
on produtos for insert
with check (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff atualiza produtos com acesso liberado"
on produtos for update
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff apaga produtos com acesso liberado"
on produtos for delete
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Cliente ve produtos do seu petshop"
on produtos for select
using (private.eh_cliente_do_petshop(petshop_id));

-- pedidos
alter table pedidos enable row level security;

create policy "Staff ve pedidos do seu petshop"
on pedidos for select
using (petshop_id = private.petshop_id());

create policy "Staff insere pedidos com acesso liberado"
on pedidos for insert
with check (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff atualiza pedidos com acesso liberado"
on pedidos for update
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff apaga pedidos com acesso liberado"
on pedidos for delete
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Cliente ve os proprios pedidos"
on pedidos for select
using (private.eh_meu_cliente_id(cliente_id));

create policy "Cliente cria pedido para si mesmo"
on pedidos for insert
with check (
  private.eh_cliente_do_petshop(petshop_id)
  and private.eh_meu_cliente_id(cliente_id)
  and private.petshop_ativo(petshop_id)
);

-- agendamentos
alter table agendamentos enable row level security;

create policy "Staff ve agendamentos do seu petshop"
on agendamentos for select
using (petshop_id = private.petshop_id());

create policy "Staff insere agendamentos com acesso liberado"
on agendamentos for insert
with check (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff atualiza agendamentos com acesso liberado"
on agendamentos for update
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Staff apaga agendamentos com acesso liberado"
on agendamentos for delete
using (petshop_id = private.petshop_id() and private.acesso_liberado());

create policy "Cliente ve agendamentos dos proprios pets"
on agendamentos for select
using (
  exists (
    select 1 from pets
    where pets.id = agendamentos.pet_id
      and private.eh_meu_cliente_id(pets.cliente_id)
  )
);

create policy "Cliente agenda para os proprios pets"
on agendamentos for insert
with check (
  private.eh_cliente_do_petshop(petshop_id)
  and private.petshop_ativo(petshop_id)
  and exists (
    select 1 from pets
    where pets.id = agendamentos.pet_id
      and private.eh_meu_cliente_id(pets.cliente_id)
  )
);

-- pets (parte do cliente, completando a PARTE 4)
create policy "Cliente ve os proprios pets"
on pets for select
using (private.eh_meu_cliente_id(cliente_id));

create policy "Cliente cadastra os proprios pets"
on pets for insert
with check (
  private.eh_cliente_do_petshop(petshop_id)
  and private.eh_meu_cliente_id(cliente_id)
  and private.petshop_ativo(petshop_id)
);

-- ============================================================
-- PARTE 7 — funcionarios (só dono/gerente gerencia)
-- ============================================================

alter table funcionarios enable row level security;

create policy "Staff ve funcionarios do seu petshop"
on funcionarios for select
using (petshop_id = private.petshop_id());

create policy "So dono ou gerente insere funcionarios com acesso liberado"
on funcionarios for insert
with check (
  petshop_id = private.petshop_id()
  and private.acesso_liberado()
  and exists (
    select 1 from usuarios_admin
    where id = auth.uid() and cargo in ('dono', 'gerente')
  )
);

create policy "So dono ou gerente atualiza funcionarios com acesso liberado"
on funcionarios for update
using (
  petshop_id = private.petshop_id()
  and private.acesso_liberado()
  and exists (
    select 1 from usuarios_admin
    where id = auth.uid() and cargo in ('dono', 'gerente')
  )
);

create policy "So dono ou gerente apaga funcionarios com acesso liberado"
on funcionarios for delete
using (
  petshop_id = private.petshop_id()
  and private.acesso_liberado()
  and exists (
    select 1 from usuarios_admin
    where id = auth.uid() and cargo in ('dono', 'gerente')
  )
);

-- ============================================================
-- PARTE 8 — Módulos (Hotel, Veterinário, Ponto)
-- ============================================================

create table modulos_ativos (
  petshop_id uuid references petshops(id),
  modulo text not null check (modulo in ('hotel', 'veterinario', 'ponto')),
  ativo boolean not null default true,
  ativado_em timestamptz not null default now(),
  primary key (petshop_id, modulo)
);

alter table modulos_ativos enable row level security;

create policy "Staff ve os proprios modulos"
on modulos_ativos for select
using (petshop_id = private.petshop_id());

create or replace function private.modulo_ativo(alvo_modulo text)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from modulos_ativos
    where petshop_id = private.petshop_id()
      and modulo = alvo_modulo
      and ativo = true
  )
$$;

revoke execute on function private.modulo_ativo(text) from public;
grant execute on function private.modulo_ativo(text) to authenticated;

-- hospedagens (módulo hotel)
alter table hospedagens enable row level security;

create policy "Staff ve hospedagens com modulo hotel ativo"
on hospedagens for select
using (petshop_id = private.petshop_id() and private.modulo_ativo('hotel'));

create policy "Staff insere hospedagens com modulo e pagamento em dia"
on hospedagens for insert
with check (petshop_id = private.petshop_id() and private.modulo_ativo('hotel') and private.acesso_liberado());

create policy "Staff atualiza hospedagens com modulo e pagamento em dia"
on hospedagens for update
using (petshop_id = private.petshop_id() and private.modulo_ativo('hotel') and private.acesso_liberado());

create policy "Staff apaga hospedagens com modulo e pagamento em dia"
on hospedagens for delete
using (petshop_id = private.petshop_id() and private.modulo_ativo('hotel') and private.acesso_liberado());

-- prontuarios (módulo veterinário)
alter table prontuarios enable row level security;

create policy "Staff ve prontuarios com modulo veterinario ativo"
on prontuarios for select
using (petshop_id = private.petshop_id() and private.modulo_ativo('veterinario'));

create policy "Staff insere prontuarios com modulo e pagamento em dia"
on prontuarios for insert
with check (petshop_id = private.petshop_id() and private.modulo_ativo('veterinario') and private.acesso_liberado());

create policy "Staff atualiza prontuarios com modulo e pagamento em dia"
on prontuarios for update
using (petshop_id = private.petshop_id() and private.modulo_ativo('veterinario') and private.acesso_liberado());

create policy "Staff apaga prontuarios com modulo e pagamento em dia"
on prontuarios for delete
using (petshop_id = private.petshop_id() and private.modulo_ativo('veterinario') and private.acesso_liberado());

-- registros_ponto (módulo controle de ponto)
alter table registros_ponto enable row level security;

create policy "Staff ve registros de ponto com modulo ativo"
on registros_ponto for select
using (petshop_id = private.petshop_id() and private.modulo_ativo('ponto'));

create policy "Staff insere registros de ponto com modulo e pagamento em dia"
on registros_ponto for insert
with check (petshop_id = private.petshop_id() and private.modulo_ativo('ponto') and private.acesso_liberado());

create policy "Staff atualiza registros de ponto com modulo e pagamento em dia"
on registros_ponto for update
using (petshop_id = private.petshop_id() and private.modulo_ativo('ponto') and private.acesso_liberado());

create policy "Staff apaga registros de ponto com modulo e pagamento em dia"
on registros_ponto for delete
using (petshop_id = private.petshop_id() and private.modulo_ativo('ponto') and private.acesso_liberado());

-- ============================================================
-- PARTE 9 — leads_interesse (formulário público)
-- ============================================================

alter table leads_interesse enable row level security;

create policy "Visitante anonimo pode enviar interesse"
on leads_interesse
for insert
to anon
with check (true);

-- Sem policy de select/update/delete para anon nem authenticated:
-- só o dono (via service_role/painel interno) lê essa lista.

-- ============================================================
-- PARTE 10 — Integridade referencial entre tenants
-- ============================================================

alter table pets add constraint pets_id_petshop_unique unique (id, petshop_id);
alter table clientes add constraint clientes_id_petshop_unique unique (id, petshop_id);

alter table agendamentos
  add constraint agendamentos_pet_mesmo_tenant
  foreign key (pet_id, petshop_id) references pets (id, petshop_id);

alter table pets
  add constraint pets_cliente_mesmo_tenant
  foreign key (cliente_id, petshop_id) references clientes (id, petshop_id);

alter table pedidos
  add constraint pedidos_cliente_mesmo_tenant
  foreign key (cliente_id, petshop_id) references clientes (id, petshop_id);

-- ============================================================
-- PARTE 11 — Leitura pública de petshops (pra resolver o slug na URL,
-- sem exigir login — ver seção 12 do documento técnico)
-- ============================================================

grant select (id, nome, slug, logo_url) on petshops to anon;

create policy "Visitante anonimo resolve petshop pelo slug"
on petshops
for select
to anon
using (status in ('ativo', 'trial'));

-- ============================================================
-- FIM. Confira no painel do Supabase (Table Editor e Authentication → Policies)
-- se todas as tabelas e políticas aparecem certinho.
-- ============================================================
