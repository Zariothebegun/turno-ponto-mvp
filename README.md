# turno-ponto

Aplicação estática de registo de ponto por QR code, com autenticação Supabase e dados persistidos em PostgreSQL. A aplicação não calcula salários.

## Preparação do Supabase

O projeto Supabase associado é `turno-ponto`. O esquema já foi aplicado ao projeto associado nas migrações `secure_qr_attendance` e `qr_session_access_and_indexes`. Os respetivos ficheiros estão em `supabase/migrations` para manter o histórico do esquema no repositório. A aplicação antiga continua a funcionar; estas alterações preparam a base de dados para a nova versão.

Para uma instalação Supabase nova, execute uma vez o conteúdo de [supabase/setup.sql](supabase/setup.sql). O script cria as tabelas, ativa RLS e configura as funções usadas pela aplicação. Não o volte a executar num projeto onde as tabelas já existem; use o histórico de migrações em vez do script de preparação.

Em Authentication, mantenha o acesso por email e palavra-passe ativado. Configure o URL do site e os URLs de redirecionamento para o domínio Render.
A chave `sb_publishable_...` e o URL do projeto aparecem em `index.html`. A chave é pública e só é segura porque o acesso às tabelas é limitado por RLS. Não coloque neste ficheiro uma chave `service_role` ou uma chave secreta.

## Publicação no Render

O site continua a ser servido como ficheiro estático. Use a raiz do repositório como diretório de publicação; não é necessário comando de compilação. A câmara exige HTTPS e autorização do browser.

## Utilização

- Um responsável cria uma conta, cria a equipa e partilha o código de convite.
- Cada funcionário cria a sua própria conta e usa o código para entrar na equipa.
- O responsável mostra o QR temporário no ecrã da equipa.
- Cada funcionário lê o código a partir da sessão autenticada. Cada código pode ser usado uma vez por funcionário, expira após dois minutos e é renovado automaticamente a cada minuto.
- O evento alterna entre entrada e saída. Os dados são limitados à equipa e à própria conta através de políticas RLS; apenas as funções SQL autorizadas podem criar registos de ponto.

## Âmbito

O QR é uma verificação de presença simples, não uma prova de localização nem um sistema de processamento salarial. A equipa deve definir as regras de utilização e retenção de dados adequadas ao seu contexto.


