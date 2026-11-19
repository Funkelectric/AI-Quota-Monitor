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

/** GET http://host:port/api/ask. True+pending on 200, true+!pending on 204, false on error. */
bool netFetchAsk(const NetConfig &cfg, struct AskState &out);

/** POST http://host:port/api/ask/answer {id, option_id}. True on 200. */
bool netPostAnswer(const NetConfig &cfg, const char *id, const char *option_id);

bool netIsConnected();
