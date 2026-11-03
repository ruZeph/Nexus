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

## Security note

The committed template deliberately contains **placeholders, not real values**. Keep it that
way:

- never paste a live client secret / API key into this file;
- pass secrets through an environment variable instead:

```js
const originalString = process.env.CREDENTIAL_BLOCK;
console.log(Buffer.from(originalString, 'utf-8').toString('base64url'));
```

If a real secret is ever committed, rotate it — rewriting history is not enough once the
repository has been pushed.
