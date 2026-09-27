# Confirmação de cadastro por código (OTP)

O cadastro usa `supabase.auth.signUp({ email, password })`. Com "Confirm
email" ligado, o Supabase envia o e-mail do template **Confirm signup** — e
não o do template **Magic Link**. Por isso mexer no Magic Link não muda nada
no cadastro.

## 1. Template de e-mail (painel do Supabase)

Authentication → Email Templates → aba **Confirm signup**:

- **Subject**: `Seu código de confirmação - PetGestor`
- **Message body**: conteúdo de
  [`supabase/templates/confirm_signup.html`](../supabase/templates/confirm_signup.html)
  (usa `{{ .Token }}`, sem `{{ .ConfirmationURL }}`).
- Salvar.

Conferir também em Authentication → Providers → Email: **Confirm email**
ligado. O tamanho do código é o de "Email OTP Length" (6 por padrão) —
a tela aceita 6 a 8 dígitos para não quebrar se isso mudar.

## 2. Frontend (tela "digite o código")

O frontend está no Lovable, fora deste repositório. Lógica a aplicar lá:

```tsx
// Cadastro: continua igual
const { error } = await supabase.auth.signUp({ email, password });
if (!error) irParaTelaDeCodigo(email); // NÃO navegar para o próximo passo aqui

// Tela de confirmação
const MAX_TENTATIVAS = 3;
const [tentativas, setTentativas] = useState(0);
const [bloqueado, setBloqueado] = useState(false);
const [confirmado, setConfirmado] = useState(false);

async function confirmarCodigo(codigoDigitado: string) {
  if (bloqueado || confirmado) return;
  const token = codigoDigitado.replace(/\D/g, "");
  if (token.length < 6 || token.length > 8) {
    setErro("Digite o código numérico recebido por e-mail.");
    return;
  }

  const { data, error } = await supabase.auth.verifyOtp({
    email,
    token,
    type: "signup",
  });

  if (error || !data.session) {
    const novas = tentativas + 1;
    setTentativas(novas);
    if (novas >= MAX_TENTATIVAS) {
      setBloqueado(true);
      await reenviarCodigo();
    } else {
      setErro(`Código inválido. Tentativas restantes: ${MAX_TENTATIVAS - novas}`);
    }
    return;
  }

  setConfirmado(true);
  irParaProximoPasso(); // só aqui o fluxo avança
}

async function reenviarCodigo() {
  const { error } = await supabase.auth.resend({ type: "signup", email });
  if (error) {
    // rate limit do Supabase (≈ 1 reenvio a cada 60s por e-mail)
    setErro("Aguarde um minuto e toque em \"Reenviar código\".");
    return;
  }
  setTentativas(0);
  setBloqueado(false);
  setErro("Você errou 3 vezes. Enviamos um novo código para o seu e-mail.");
}
```

Pontos que costumam causar o "volta pra tela inicial":

- `verifyOtp` cria a sessão e dispara `SIGNED_IN` no
  `onAuthStateChange`. Se existir um listener global que faz
  `navigate("/")` em `SIGNED_IN`, ele atropela o fluxo — o listener tem que
  ignorar esse evento enquanto o usuário está na tela de código (ou a
  navegação fica só em `confirmarCodigo`).
- Remover `emailRedirectTo` do `signUp` (não há mais link) e qualquer
  lógica que espera `#access_token` / `?code=` na URL para "confirmar".
- Rotas dos passos seguintes devem exigir usuário com
  `email_confirmed_at` preenchido, para não dar pra pular a tela de código.

## 3. Teste

1. Cadastrar com um e-mail novo (nunca usado).
2. O e-mail recebido deve ter só o código numérico, sem link de confirmação.
   Se vier link, o template salvo não é o "Confirm signup".
3. Digitar o código → deve avançar para o próximo passo, sem ir para a tela
   inicial.
4. Errar 3 vezes → campo bloqueia e um novo código chega por e-mail; o código
   antigo deixa de valer.

Obs.: o SMTP padrão do Supabase limita o envio a poucos e-mails por hora.
Se o e-mail não chegar durante os testes, é esse limite (ou configure SMTP
próprio em Authentication → SMTP Settings).
