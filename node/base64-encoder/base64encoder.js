// Base64url-encode a multi-line credential block for copy-paste into an API client or CI var.
//
// NEVER put a real secret in this file - it is committed. Either edit the placeholder block
// below by hand and run it, or feed the block in through an environment variable:
//
//   $env:CREDENTIAL_BLOCK = @'
//   Name: <app-name>
//   Client ID: <client-id>
//   ...
//   '@
//   node base64encoder.js
//
// See README.md in this folder for details.

const originalString = process.env.CREDENTIAL_BLOCK || `Name: <app-name>
Client ID: <client-id>
Credential Type: secret
Client Secret: <client-secret>
Read-only: false
Token URL: https://<subdomain>.authentication.<region>.hana.ondemand.com/oauth/token
API URL: https://api.authentication.<region>.hana.ondemand.com`;

const encodedString = Buffer.from(originalString, "utf-8").toString('base64url');
console.log(encodedString);
