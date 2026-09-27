# ColeirasCaes

Projeto iPhone (iOS 17+) que recebe DOG01 e DOG02 através do serviço BLE do
Raspberry Pi. A interface mostra um mapa com as duas coleiras, enquadramento
automático, percurso da sessão, coordenadas, satélites, bateria, hora da última
receção e intensidade do sinal. Também mostra a posição do próprio iPhone,
mediante autorização de localização, com botão para a centrar no mapa.
O Raspberry executa `caes_ble_corrigido.py`.

O workflow Codemagic compila **sem assinatura**, para verificar o código.
O resultado `.app` não pode ser instalado no iPhone sem assinatura Apple.
O `.app.zip` pode ser convertido em `.ipa` e instalado pelo Sideloadly com uma
conta Apple gratuita; a instalação precisa de ser renovada periodicamente.

Para usar este repositório: extrair o ZIP, abrir a pasta `ColeirasCaes_iOS` e
carregar **o conteúdo dessa pasta** para a raiz do repositório `coleiras` no
GitHub. No Codemagic, premir «Check for configuration files».
