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
 * Opens the AI-Quota-Setup captive portal when no credentials are stored
 * (portalTimeoutMs) or when forcePortal is true (BOOT long-press path).
 */
bool netEnsureWiFi(NetConfig &cfg, bool forcePortal, unsigned long portalTimeoutMs = 180000);

/** GET http://host:port/api/quota into out. False on any transport/parse error. */
bool netFetchQuota(const NetConfig &cfg, struct QuotaState &out);

/** GET http://host:port/api/ask. True+pending on 200, true+!pending on 204, false on error. */
bool netFetchAsk(const NetConfig &cfg, struct AskState &out);

/** POST http://host:port/api/ask/answer {id, option_id}. True on 200. */
bool netPostAnswer(const NetConfig &cfg, const char *id, const char *option_id);

/** POST http://host:port/api/endofwork/dismiss {id}. True on 200. */
bool netPostEndDismiss(const NetConfig &cfg, const char *id);

/**
 * Non-blocking WiFi maintenance (AUDIT C1 / P0-1).
 * Call every loop(): when offline, attempts WiFi.reconnect() at most every
 * WIFI_RECONNECT_SEC and re-runs NTP (configTzTime) once on regain.
 * Never blocks; never opens the portal (portal only via BOOT long-press).
 */
void netTick();

bool netIsConnected();

/** Optional bearer for POST /api/ask/answer when bridge sets CYD_TOKEN (P3-17). */
void netSetToken(const char *token);
