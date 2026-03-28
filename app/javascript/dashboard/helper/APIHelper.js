import Auth from '../api/auth';

const parseErrorCode = error => Promise.reject(error);

export default axios => {
  const { apiHost = '' } = window.chatwootConfig || {};
  const wootApi = axios.create({ baseURL: `${apiHost}/` });
  // Add Auth Headers to requests if logged in
  if (Auth.hasAuthCookie()) {
    const authData = Auth.getAuthData();
    // iframe token-based auth: use api_access_token header
    if (authData.api_access_token) {
      Object.assign(wootApi.defaults.headers.common, {
        api_access_token: authData.api_access_token,
      });
    } else {
      const {
        'access-token': accessToken,
        'token-type': tokenType,
        client,
        expiry,
        uid,
      } = authData;
      Object.assign(wootApi.defaults.headers.common, {
        'access-token': accessToken,
        'token-type': tokenType,
        client,
        expiry,
        uid,
      });
    }
  }
  // Response parsing interceptor
  wootApi.interceptors.response.use(
    response => response,
    error => parseErrorCode(error)
  );
  return wootApi;
};
