#pragma once
#include <Arduino.h>
#include "config.h"

struct NetConfig {
  char host[64];
  uint16_t port;
  uint16_t poll_sec;
};

void configLoad(NetConfig &cfg);
void configSave(const NetConfig &cfg);

/**
 * Bring up WiFi. Returns true when connected.
 * Opens the NM-Quota-Setup captive portal when no credentials are stored
 * (portalTimeoutMs) or when forcePortal is true (BOOT long-press path).
 */
bool netEnsureWiFi(NetConfig &cfg, bool forcePortal, unsigned long portalTimeoutMs = 180000);

/** GET http://host:port/api/quota into out. False on any transport/parse error. */
bool netFetchQuota(const NetConfig &cfg, struct QuotaState &out);

bool netIsConnected();
