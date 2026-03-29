import { computed, unref } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConfig } from 'dashboard/composables/useConfig';
import {
  getUserPermissions,
  hasPermissions,
} from 'dashboard/helper/permissionsHelper';
import { PREMIUM_FEATURES } from 'dashboard/featureFlags';

import { INSTALLATION_TYPES } from 'dashboard/constants/installationTypes';

export function usePolicy() {
  const user = useMapGetter('getCurrentUser');
  const isFeatureEnabled = useMapGetter('accounts/isFeatureEnabledonAccount');
  const isOnChatwootCloud = useMapGetter('globalConfig/isOnChatwootCloud');
  const isACustomBrandedInstance = useMapGetter(
    'globalConfig/isACustomBrandedInstance'
  );

  const { isEnterprise, enterprisePlanName } = useConfig();
  const { accountId } = useAccount();

  const getUserPermissionsForAccount = () => {
    return getUserPermissions(user.value, accountId.value);
  };

  const isFeatureFlagEnabled = featureFlag => {
    if (!featureFlag) return true;
    return isFeatureEnabled.value(accountId.value, featureFlag);
  };

  const checkPermissions = requiredPermissions => {
    if (!requiredPermissions || !requiredPermissions.length) return true;
    const userPermissions = getUserPermissionsForAccount();
    return hasPermissions(requiredPermissions, userPermissions);
  };

  const checkInstallationType = config => {
    if (Array.isArray(config) && config.length > 0) {
      const installationCheck = {
        [INSTALLATION_TYPES.ENTERPRISE]: isEnterprise,
        [INSTALLATION_TYPES.CLOUD]: isOnChatwootCloud.value,
        [INSTALLATION_TYPES.COMMUNITY]: true,
      };

      return config.some(type => installationCheck[type]);
    }

    return true;
  };

  const isPremiumFeature = featureFlag => {
    if (!featureFlag) return true;
    return PREMIUM_FEATURES.includes(featureFlag);
  };

  const hasPremiumEnterprise = computed(() => {
    if (isEnterprise) return enterprisePlanName !== 'community';

    return true;
  });

  const shouldShow = (featureFlag, permissions, installationTypes) => {
    const perms = unref(permissions);
    const installation = unref(installationTypes);

    // Adalink: only check permissions and installation type, all features unlocked
    if (!checkPermissions(perms)) return false;
    if (!checkInstallationType(installation)) return false;
    return true;
  };

  const shouldShowPaywall = featureFlag => {
    const flag = unref(featureFlag);
    if (!flag) return false;

    if (isACustomBrandedInstance.value) {
      // custom branded instances never show paywall
      return false;
    }

    if (isPremiumFeature(flag)) {
      if (isOnChatwootCloud.value) {
        return !isFeatureFlagEnabled(flag);
      }

      if (isEnterprise) {
        return !hasPremiumEnterprise.value;
      }
    }

    return false;
  };

  return {
    checkPermissions,
    shouldShowPaywall,
    isFeatureFlagEnabled,
    shouldShow,
  };
}
