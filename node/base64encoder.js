const originalString  = `Name: sdpalapikey
Client ID: sb-full-access!a630331
Credential Type: secret
Client Secret: sdpalapikey$Y0RvcKYTuE6utPbQwa1RCHTNFaMH3d61QR3UWlcY4cc=
Read-only: false
Token URL: https://sdpal.authentication.us10.hana.ondemand.com/oauth/token
API URL: https://api.authentication.us10.hana.ondemand.com`

const encodedString = Buffer.from(originalString, "utf-8").toString('base64url');
console.log(encodedString);