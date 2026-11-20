#include "network.h"
#include "quota_state.h"
#include "ask_state.h"
#include <HTTPClient.h>
#include <Preferences.h>
#include <WiFi.h>
#include <WiFiManager.h>
#include <string.h>
#include <time.h>

void configLoad(NetConfig &cfg) {
  strncpy(cfg.host, BRIDGE_HOST_DEFAULT, sizeof(cfg.host) - 1);
  cfg.host[sizeof(cfg.host) - 1] = '\0';
  cfg.port = BRIDGE_PORT_DEFAULT;
  cfg.poll_sec = POLL_INTERVAL_SEC_DEFAULT;

  Preferences p;
  if (!p.begin(NVS_NS, true)) return;
  // AUDIT M3: no Arduino String on the read path (heap-stable); getString
  // directly into a stack buffer, then copy with truncation guard.
  char hbuf[sizeof(cfg.host)];
  size_t n = p.getString(NVS_KEY_HOST, hbuf, sizeof(hbuf));
  if (n > 0) {
    strncpy(cfg.host, hbuf, sizeof(cfg.host) - 1);
    cfg.host[sizeof(cfg.host) - 1] = '\0';
  }
  cfg.port = p.getUShort(NVS_KEY_PORT, cfg.port);
  cfg.poll_sec = p.getUShort(NVS_KEY_POLL, cfg.poll_sec);
  if (cfg.poll_sec < 5) cfg.poll_sec = 5;
  if (cfg.poll_sec > 300) cfg.poll_sec = 300;
  p.end();
}

void configSave(const NetConfig &cfg) {
  Preferences p;
  if (!p.begin(NVS_NS, false)) return;
  p.putString(NVS_KEY_HOST, cfg.host);
  p.putUShort(NVS_KEY_PORT, cfg.port);
  p.putUShort(NVS_KEY_POLL, cfg.poll_sec);
  p.end();
}

static char g_host[64];
static char g_port[8];
static char g_poll[8];
static bool g_save = false;

static void saveParamsCallback() { g_save = true; }

bool netEnsureWiFi(NetConfig &cfg, bool forcePortal, unsigned long portalTimeoutMs) {
  // AUDIT C1: stay in STA + auto-reconnect so roams/DHCP expiry recover.
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.persistent(true);
  if (WiFi.status() == WL_CONNECTED && !forcePortal) return true;
  WiFiManager wm;
  wm.setTitle("AI Quota Monitor");
  wm.setConfigPortalTimeout(portalTimeoutMs / 1000);

  snprintf(g_host, sizeof(g_host), "%s", cfg.host);
  snprintf(g_port, sizeof(g_port), "%u", cfg.port);
  snprintf(g_poll, sizeof(g_poll), "%u", cfg.poll_sec);

  WiFiManagerParameter p_host("br_host", "Bridge host", g_host, sizeof(g_host));
  WiFiManagerParameter p_port("br_port", "Bridge port", g_port, sizeof(g_port));
  WiFiManagerParameter p_poll("poll_sec", "Poll interval (s)", g_poll, sizeof(g_poll));
  wm.addParameter(&p_host);
  wm.addParameter(&p_port);
  wm.addParameter(&p_poll);
  wm.setSaveParamsCallback(saveParamsCallback);

  bool ok;
  if (forcePortal) {
    wm.setConfigPortalTimeout(0);  // stay open until configured
    ok = wm.startConfigPortal(WIFI_AP_NAME);
  } else {
    ok = wm.autoConnect(WIFI_AP_NAME);
  }

  if (ok) {
    strncpy(cfg.host, p_host.getValue(), sizeof(cfg.host) - 1);
    cfg.port = (uint16_t)atoi(p_port.getValue());
    cfg.poll_sec = (uint16_t)atoi(p_poll.getValue());
    if (cfg.port == 0) cfg.port = BRIDGE_PORT_DEFAULT;
    if (cfg.poll_sec < 5 || cfg.poll_sec > 300) cfg.poll_sec = POLL_INTERVAL_SEC_DEFAULT;
    if (g_save) {
      configSave(cfg);
      g_save = false;
    }
    // NTP for the header/clock screen (best effort).
    configTzTime(NTP_TZ, NTP_SERVER_1, NTP_SERVER_2);
  }
  return ok && WiFi.status() == WL_CONNECTED;
}

// Shared fetch buffer: single static allocation, reused every poll.
static char g_buf[QUOTA_JSON_MAX + 1];

bool netFetchQuota(const NetConfig &cfg, QuotaState &out) {
  if (WiFi.status() != WL_CONNECTED) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/quota", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  int code = http.GET();
  bool ok = false;
  if (code == 200) {
    // AUDIT M2: reject oversize bodies up-front; chunked (-1) still bounded
    // by QUOTA_JSON_MAX + the 1.5s stall heuristic below.
    int len = http.getSize();
    if (len > QUOTA_JSON_MAX) {
      http.end();
      return false;
    }
    if (len < 0) len = QUOTA_JSON_MAX;
    WiFiClient *stream = http.getStreamPtr();
    size_t n = 0;
    unsigned long deadline = millis() + HTTP_TIMEOUT_MS;
    unsigned long lastProgress = millis();
    while (n < (size_t)len && millis() < deadline) {
      while (stream->available() && n < QUOTA_JSON_MAX) {
        g_buf[n++] = (char)stream->read();
        lastProgress = millis();
      }
      if ((int)n >= len && len > 0) break;
      if (millis() - lastProgress > 1500) break;  // stalled body: parse what we have
      delay(1);
    }
    ok = parseQuotaPayload(g_buf, n, out);
  }
  http.end();
  return ok;
}

static unsigned long s_lastReconnectTry = 0;
static bool s_ntpDone = false;

void netTick() {
  // Called every loop(). Non-blocking: at most one reconnect attempt per
  // WIFI_RECONNECT_SEC, no portal, no delay().
  if (WiFi.status() == WL_CONNECTED) {
    if (!s_ntpDone) {
      // Regained link (or first connect without portal path): re-sync clock.
      configTzTime(NTP_TZ, NTP_SERVER_1, NTP_SERVER_2);
      s_ntpDone = true;
    }
    return;
  }
  unsigned long now = millis();
  if (now - s_lastReconnectTry < WIFI_RECONNECT_MS) return;
  s_lastReconnectTry = now;
  s_ntpDone = false;
  WiFi.disconnect(false, false);
  WiFi.reconnect();
}

bool netIsConnected() { return WiFi.status() == WL_CONNECTED; }

// Shared ask buffer (separate from quota buffer so polls never interleave).
static char g_askBuf[ASK_JSON_MAX + 1];

bool netFetchAsk(const NetConfig &cfg, AskState &out) {
  if (WiFi.status() != WL_CONNECTED) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/ask", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  int code = http.GET();
  if (code == 204) {
    http.end();
    out.pending = false;
    out.fresh = true;
    return true;
  }
  bool ok = false;
  if (code == 200) {
    int len = http.getSize();
    if (len > ASK_JSON_MAX) {
      http.end();
      return false;
    }
    if (len < 0) len = ASK_JSON_MAX;
    WiFiClient *stream = http.getStreamPtr();
    size_t n = 0;
    unsigned long deadline = millis() + HTTP_TIMEOUT_MS;
    unsigned long lastProgress = millis();
    while (n < (size_t)len && millis() < deadline) {
      while (stream->available() && n < ASK_JSON_MAX) {
        g_askBuf[n++] = (char)stream->read();
        lastProgress = millis();
      }
      if ((int)n >= len && len > 0) break;
      if (millis() - lastProgress > 1500) break;
      delay(1);
    }
    ok = parseAskPayload(g_askBuf, n, out);
  }
  http.end();
  return ok;
}

static char s_token[64] = "";

void netSetToken(const char *token) {
  if (!token) token = "";
  strncpy(s_token, token, sizeof(s_token) - 1);
  s_token[sizeof(s_token) - 1] = '\0';
}

bool netPostAnswer(const NetConfig &cfg, const char *id, const char *option_id) {
  if (WiFi.status() != WL_CONNECTED || !id || !option_id) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/ask/answer", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  http.addHeader("Content-Type", "application/json");
  if (s_token[0]) {
    char auth[80];
    snprintf(auth, sizeof(auth), "Bearer %.64s", s_token);
    http.addHeader("Authorization", auth);
  }
  // ASK_ID_MAX=31 unified with bridge (AUDIT C3). Body sized for 31+31 + JSON.
  char body[128];
  snprintf(body, sizeof(body), "{\"id\":\"%.31s\",\"option_id\":\"%.31s\"}", id, option_id);
  int code = http.POST((uint8_t *)body, strlen(body));
  http.end();
  return code == 200;
}

bool netPostEndDismiss(const NetConfig &cfg, const char *id) {
  if (WiFi.status() != WL_CONNECTED || !id) return false;
  char url[128];
  snprintf(url, sizeof(url), "http://%s:%u/api/endofwork/dismiss", cfg.host, cfg.port);

  HTTPClient http;
  http.setTimeout(HTTP_TIMEOUT_MS);
  if (!http.begin(url)) return false;
  http.addHeader("Content-Type", "application/json");
  if (s_token[0]) {
    char auth[80];
    snprintf(auth, sizeof(auth), "Bearer %.64s", s_token);
    http.addHeader("Authorization", auth);
  }
  char body[64];
  snprintf(body, sizeof(body), "{\"id\":\"%.31s\"}", id);
  int code = http.POST((uint8_t *)body, strlen(body));
  http.end();
  return code == 200;
}
