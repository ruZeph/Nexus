// base64url-encode a multi-line block for copy-paste into an API client or CI variable.
//
// Usage:
//   $env:CREDENTIAL_BLOCK = @'
//   <block contents>
//   '@
//   node base64encoder.js
//
// Or edit the placeholder block below by hand. Output is URL-safe base64 (base64url),
// matching Buffer.toString('base64url').
//
// See README.md in this folder for details.

const originalString = process.env.CREDENTIAL_BLOCK || `Name: <name>
Client ID: <client-id>
Credential Type: <type>
Client Secret: <secret>
Read-only: <true|false>
Token URL: <token-url>
API URL: <api-url>`;

const encodedString = Buffer.from(originalString, "utf-8").toString('base64url');
console.log(encodedString);
