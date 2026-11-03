# Base64 Encoder

Part of the **[Nexus](../../README.md)** toolkit — `node/base64-encoder/`.

Tiny Node one-liner used to turn a multi-line credential block into a single
`base64url` token for copy-paste into an API client or CI variable.

## Usage

1. Replace the `originalString` template literal with the text to encode.
2. Run it:

```bash
node base64encoder.js
```

Output is a URL-safe Base64 string (`base64url`: `+`→`-`, `/`→`_`, no padding), matching what
`Buffer.toString('base64url')` produces.

## Notes

The template in `base64encoder.js` is a **placeholder** — field names only. Supply the real
values through the `CREDENTIAL_BLOCK` environment variable:

```bash
CREDENTIAL_BLOCK="$SOME_VALUE" node base64encoder.js     # bash
```

```powershell
$env:CREDENTIAL_BLOCK = '<block>'; node base64encoder.js  # PowerShell
```

Keep credentials out of the working tree: this file is committed, and anything written into it
ends up in shared history.
