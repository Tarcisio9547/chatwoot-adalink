/* eslint-disable no-console */
import NotificationSubscriptions from '../api/notificationSubscription';
import auth from '../api/auth';

export const verifyServiceWorkerExistence = (callback = () => {}) => {
  if (!('serviceWorker' in navigator)) {
    // Service Worker isn't supported on this browser, disable or hide UI.
    return;
  }

  if (!('PushManager' in window)) {
    // Push isn't supported on this browser, disable or hide UI.
    return;
  }

  navigator.serviceWorker
    .register('/sw.js')
    .then(registration => callback(registration))
    .catch(registrationError => {
      // eslint-disable-next-line
      console.log('SW registration failed: ', registrationError);
    });
};

export const hasPushPermissions = () => {
  if ('Notification' in window) {
    return Notification.permission === 'granted';
  }
  return false;
};

const generateKeys = str =>
  btoa(String.fromCharCode.apply(null, new Uint8Array(str)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_');

export const getPushSubscriptionPayload = subscription => ({
  subscription_type: 'browser_push',
  subscription_attributes: {
    endpoint: subscription.endpoint,
    p256dh: generateKeys(subscription.getKey('p256dh')),
    auth: generateKeys(subscription.getKey('auth')),
  },
});

export const sendRegistrationToServer = subscription => {
  if (auth.hasAuthCookie()) {
    return NotificationSubscriptions.create(
      getPushSubscriptionPayload(subscription)
    );
  }
  return null;
};

export const registerSubscription = (onSuccess = () => {}) => {
  if (!window.chatwootConfig.vapidPublicKey) {
    return;
  }
  navigator.serviceWorker.ready
    .then(serviceWorkerRegistration =>
      serviceWorkerRegistration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: window.chatwootConfig.vapidPublicKey,
      })
    )
    .then(sendRegistrationToServer)
    .then(() => {
      onSuccess();
    })
    .catch(error => {
      // eslint-disable-next-line no-console
      console.error('Push subscription registration failed:', error);
      // NÃO mostrar toast: dentro do iframe do CRM o push subscription falha
      // sempre (cross-origin / applicationServerKey já existe), e o toast
      // "This browser does not support desktop notification" aparecia pro
      // usuário ao abrir o modal de atendimento — ruído sem ação possível.
      // Mantém o console.error pra debug.
    });
};

export const requestPushPermissions = ({ onSuccess }) => {
  if (!('Notification' in window)) {
    // eslint-disable-next-line no-console
    console.warn('Notification is not supported');
    // Sem toast: ruído sem ação possível pro usuário (ver catch em
    // registerSubscription). Só loga.
  } else if (Notification.permission === 'granted') {
    registerSubscription(onSuccess);
  } else if (Notification.permission !== 'denied') {
    Notification.requestPermission(permission => {
      if (permission === 'granted') {
        registerSubscription(onSuccess);
      }
    });
  }
};
