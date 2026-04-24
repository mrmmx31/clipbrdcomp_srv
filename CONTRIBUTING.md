# Contributing

Obrigado pelo interesse em contribuir com o ClipBrdComp Broker.

Como contribuir:

- Abra uma issue para reportar bugs ou propor funcionalidades.
- Faça um fork do repositório e crie uma branch com um nome descritivo (ex.: feat/nova-funcao ou fix/corrigir-erro).
- Faça commits pequenos e descritivos.
- Abra um Pull Request apontando para a branch `main`.

Build e testes locais:

1. Instale o Free Pascal (`fpc`).
2. Compile com:

```
fpc -Fu../protocol -Fu../compat clipbrd_broker.lpr
```

Regras básicas:

- Mantenha o estilo do código existente.
- Inclua alterações no `README.md` quando necessário.
- Certifique-se de que o CI (`.github/workflows/ci.yml`) passe antes de solicitar o merge.

Obrigado!
