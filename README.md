# noctalia-plugins-jp

My plugins for noctalia shell v5+
- [bubblemail](bubblemail/)

## Using this repo as a plugin source

```console
$ noctalia msg plugins source add jamespo git https://github.com/jamespo/noctalia-plugins-jp
$ noctalia msg plugins enable jamespo/bubblemail
```

Noctalia requires a root [`catalog.toml`](catalog.toml) on a git source — it is
the index it renders and compat-checks the plugin list from before anything is
enabled. Regenerate it from the plugins' manifests after any version,
description or tag change, and commit it:

```console
$ ./update-catalog.py
```
