# rockskipping-cert

Published TLS certificate for `play.skiprocking.ca`, used by
[Rock Skipping](https://github.com/Ajw2003/RockSkipping) so phone browsers get a secure
context — which is what the DeviceMotion sensor APIs require.

## The private key in this repo is public on purpose

That is not a leak. Phone motion sensors need a secure context, a secure context needs a
publicly trusted certificate, and a certificate needs a name — but the machine serving the
game sits on a private hotspot address that no CA will ever certify. Publishing the key is
what breaks that circle, exactly as the late `local-ip.sh` did before it went offline.

It therefore proves nothing about who is serving. It only unlocks the sensor APIs. Nothing
sensitive travels over it, and the certificate covers exactly one name so that holding this
key grants nothing anywhere else.

## Contents

Both files are release assets on the `current` tag, replaced in place on every renewal so
the download URL never moves:

- `server.pem` — full chain
- `server.key` — private key

Renewed automatically by `.github/workflows/renew-cert.yml` in the game repository.