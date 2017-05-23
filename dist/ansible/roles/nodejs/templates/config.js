module.exports = {
  // App Settings
  TOKEN_SECRET: '{{jwt_token_secret}}',
  PORT: 80,

  // OAuth 2.0
  //TODO Make these parameters more generic. Just write out all params that exist at etcd path
  // Google
  GOOGLE_CLIENT_ID: '{{google_client_id}}',
  GOOGLE_REDIRECT_URI: '{{google_redirect_uri}}',
  GOOGLE_SECRET: '{{google_auth_secret}}'
};
