# ClipBrdComp Broker

[![CI](https://github.com/mrmmx31/clipbrdcomp_srv/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mrmmx31/clipbrdcomp_srv/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Repositório local inicializado com .gitignore e instruções básicas.

Build
-----
Compile com Free Pascal usando:

```
fpc -Fu../protocol -Fu../compat clipbrd_broker.lpr
```

Config
------
Edite o ficheiro `broker.ini` conforme necessário antes de executar.

Push
----
Depois de confirmar localmente, use o comando `gh repo create` ou `git remote add` e `git push` para subir ao GitHub.

Contributing
----------
Veja [CONTRIBUTING.md](CONTRIBUTING.md) para orientações sobre como contribuir.
