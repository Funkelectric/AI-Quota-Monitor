#include "screens.h"
#include "display.h"
#include "ask_state.h"
#include "ui_theme.h"
#include "config.h"
#include <math.h>

uint16_t statusColor(uint8_t status) {
  switch (status) {
    case ST_OK: return COLOR_GREEN;
    case ST_WARN: return COLOR_AMBER;
    case ST_CRIT: return COLOR_RED;
    default: return COLOR_BLUE;
  }
}

static uint16_t darken(uint16_t c) { return ((c >> 1) & 0x7BEF); }

static const char *screenSection(uint8_t scr) {
  // AUDIT H3: ASCII '-' only. TFT_eSPI bitmap fonts (font1/font2) are 7-bit;
  // UTF-8 middle-dot renders as two garbage glyphs on-device.
  switch (scr) {
#ifdef TV154
    // 240px: "02 - PROVIDERS" (130px spaced) collides with the clock cluster;
    // "02 - WINDOWS" (114px) keeps an 8px gap (see mock_tv154_render.py audit).
    case SCR_PROVIDERS: return "02 - WINDOWS";
#else
    case SCR_PROVIDERS: return "02 - PROVIDERS";
#endif
    case SCR_SCOPE: return "03 - SCOPE";
    case SCR_CLOCK: return "04 - STANDBY";
    case SCR_ASK: return "05 - ASK";
    case SCR_ENDWORK: return "END - WORK";
    default: return "01 - QUOTA";
  }
}
extern uint8_t g_screen;  // owned by main.cpp

// Letterspaced micro label, analyzer-style.
static void spaced(const char *s, int x, int y, uint16_t color, uint16_t bg, uint8_t tracking = 2) {
  TFT_eSPI &t = display();
  t.setTextFont(2);
  t.setTextColor(color, bg);
  int cx = x;
  for (const char *c = s; *c; c++) {
    char b[2] = {*c, 0};
    t.setCursor(cx, y);
    t.print(b);
    cx += t.textWidth(b) + tracking;
  }
}

static void tiny(const char *s, int x, int y, uint16_t color, uint16_t bg) {
  TFT_eSPI &t = display();
  t.setTextFont(1);
  t.setTextColor(color, bg);
  t.setCursor(x, y);
  t.print(s);
}

static void header(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.setTextSize(1);
  t.setTextDatum(TL_DATUM);
  t.fillRect(0, 0, LAYOUT_W, HEADER_H, COLOR_CARD);
  spaced(screenSection(g_screen), 10, 6, COLOR_DIM, COLOR_CARD);

  uint16_t dot;
  const char *live;
  if (!q.fresh || !q.oc_connected) { dot = COLOR_DIM; live = "----"; }
  else if (q.oc_stale) { dot = COLOR_AMBER; live = "STALE"; }
  else { dot = COLOR_ICE; live = "LIVE"; }
  const char *link = serialMode ? "USB" : (netUp ? "WIFI" : "--");
  char clk[16];
  struct tm tm;
  if (getLocalTime(&tm, 0)) {
    snprintf(clk, sizeof(clk), "%02d:%02d", tm.tm_hour, tm.tm_min);
  } else if (q.fresh) {
    snprintf(clk, sizeof(clk), "-%lus", (millis() - q.updated_ms) / 1000);
  } else {
    snprintf(clk, sizeof(clk), "--:--");
  }

  // Right cluster packed from the edge: LIVE badge, link, clock. Never overlaps.
  t.setTextFont(2);
  int cx = LAYOUT_W - 10;
  t.setTextColor(dot, COLOR_CARD);
  int tw = t.textWidth(live);
  t.setCursor(cx - tw, 6);
  t.print(live);
  t.fillCircle(cx - tw - 8, HEADER_H / 2, 4, dot);
  cx -= tw + 18;
  t.setTextColor(COLOR_DIM, COLOR_CARD);
  tw = t.textWidth(link);
  t.setCursor(cx - tw, 6);
  t.print(link);
  cx -= tw + 8;
  tw = t.textWidth(clk);
  t.setCursor(cx - tw, 6);
  t.print(clk);
  t.drawFastHLine(0, HEADER_H, LAYOUT_W, COLOR_EDGE);
}

// Gradient meter bar with a white threshold marker at 20%.
static void meterBar(int x, int y, int w, int h, float pct, uint8_t status) {
  TFT_eSPI &t = display();
  t.drawRoundRect(x, y, w, h, 3, COLOR_EDGE);
  t.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 2, COLOR_BG);
  float c = constrain(pct, 0, 100);
  int fill = (int)((c / 100.0f) * (w - 4));
  if (fill > 0) {
    uint16_t col = statusColor(status);
    t.fillRectHGradient(x + 2, y + 2, fill, h - 4, darken(col), col);
  }
  // crit-threshold marker
  int mx = x + 2 + (int)(0.2f * (w - 4));
  t.drawFastVLine(mx, y + 1, h - 2, COLOR_TEXT);
}

// Legacy right-aligned pair (kept for 03 SCOPE narrow column).
static void rightPair(int y, const PoolState &p, int right) {
  TFT_eSPI &t = display();
  char cd[12];
  fmtCountdown(p.reset_in_sec, cd, sizeof(cd));
  char pct[10];
  snprintf(pct, sizeof(pct), "%.1f", p.remaining_pct);
  t.setTextFont(4);
  t.setTextColor(statusColor(p.status), COLOR_BG);
  int pw = t.textWidth(pct);
  t.setCursor(right - pw, y);
  t.print(pct);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor(right - pw + 2, y + 26);
  t.print("%");
  t.setCursor(right - 62, y + 26);
  t.print(cd);
}

// Centered value: big % near-center, countdown right-aligned + readable.
// CYD: % anchors at x=180 (not 160) so long "GO MONTH" labels never overlap.
// TV154 240px: free zone is label-end (~92) .. countdown-start (~174),
// so anchor at 132 (see mock_tv154_render.py audit).
static void centerPair(int y, const PoolState &p, int right) {
  TFT_eSPI &t = display();
  char cd[12];
  fmtCountdown(p.reset_in_sec, cd, sizeof(cd));
  char pct[12];
  snprintf(pct, sizeof(pct), "%.1f%%", p.remaining_pct);
  t.setTextFont(4);
  t.setTextColor(statusColor(p.status), COLOR_BG);
  int pw = t.textWidth(pct);
#ifdef TV154
  t.setCursor(TV154_CENTER_X - pw / 2, y);
#else
  t.setCursor(180 - pw / 2, y);
#endif
  t.print(pct);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  int cw = t.textWidth(cd);
  t.setCursor(right - cw, y + 8);
  t.print(cd);
}

// Bottom readout strip: TOKENS | VER | NEXT, EBU-style.
static void readoutStrip(const QuotaState &q) {
  TFT_eSPI &t = display();
  const int y = LAYOUT_H - 30;
  t.drawFastHLine(MARGIN, y, LAYOUT_W - 2 * MARGIN, COLOR_EDGE);
  char v0[16], v2[16];
  if (q.oc_tokens_k >= 1000) snprintf(v0, sizeof(v0), "%.1fM", q.oc_tokens_k / 1000.0f);
  else snprintf(v0, sizeof(v0), "%.0fk", q.oc_tokens_k);
  if (q.oc_count) fmtCountdown(minReset(q), v2, sizeof(v2));
  else snprintf(v2, sizeof(v2), "--");

#ifdef TV154
  const int c0 = TV154_C0, c1 = TV154_C1, c2 = TV154_C2;
#else
  const int c0 = MARGIN + 4, c1 = 118, c2 = 216;
#endif
  tiny("TOKENS", c0, y + 5, COLOR_DIM, COLOR_BG);
  tiny("VER", c1, y + 5, COLOR_DIM, COLOR_BG);
  tiny("NEXT", c2, y + 5, COLOR_DIM, COLOR_BG);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor(c0, y + 14);
  t.print(v0);
  t.setCursor(c1, y + 14);
  t.print(FW_VERSION);
  t.setTextColor(q.fresh ? COLOR_ICE : COLOR_DIM, COLOR_BG);
  t.setCursor(c2, y + 14);
  t.print(v2);
#ifdef TV154
  t.drawFastVLine(TV154_DIV0, y + 4, 22, COLOR_EDGE);
  t.drawFastVLine(TV154_DIV1, y + 4, 22, COLOR_EDGE);
#else
  t.drawFastVLine(110, y + 4, 22, COLOR_EDGE);
  t.drawFastVLine(208, y + 4, 22, COLOR_EDGE);
#endif
}

// Hero quota curve: cosine-interpolated area through the window levels.
// Panel geometry 320x240: x 8..312, y 36..172. TV154 240x240: x 8..231.
#ifdef TV154
#define HERO_X0 8
#define HERO_X1 TV154_HERO_X1
#else
#define HERO_X0 8
#define HERO_X1 312
#endif
#define HERO_Y0 36
#define HERO_Y1 172
#define HERO_STEP 2
#define HERO_SAMPLES ((HERO_X1 - HERO_X0) / HERO_STEP + 1)

static int s_curveY[HERO_SAMPLES];

static uint16_t lerp565(uint16_t a, uint16_t b, uint8_t t /*0..255*/) {
  int ar = (a >> 11) & 0x1F, ag = (a >> 5) & 0x3F, ab = a & 0x1F;
  int br = (b >> 11) & 0x1F, bg = (b >> 5) & 0x3F, bb = b & 0x1F;
  int r = ar + ((br - ar) * t >> 8);
  int g = ag + ((bg - ag) * t >> 8);
  int bl = ab + ((bb - ab) * t >> 8);
  return (uint16_t)((r << 11) | (g << 5) | bl);
}

// Sample the smooth level curve. Levels: remaining% per provider, n>=1.
static void sampleCurve(const float *levels, uint8_t n) {
  float xs[POOLS_MAX], ys[POOLS_MAX];
  for (uint8_t i = 0; i < n; i++) {
    xs[i] = HERO_X0 + (i + 0.5f) * (HERO_X1 - HERO_X0) / n;
    float c = constrain(levels[i], 0, 100) / 100.0f;
    ys[i] = (HERO_Y1 - 6) - c * (HERO_Y1 - HERO_Y0 - 30);
  }
  for (int s = 0; s < HERO_SAMPLES; s++) {
    float x = HERO_X0 + s * HERO_STEP;
    float y;
    if (n < 2) {
      y = ys[0];
    } else if (x <= xs[0]) {
      y = ys[0];
    } else if (x >= xs[n - 1]) {
      y = ys[n - 1];
    } else {
      uint8_t k = 0;
      while (k < n - 2 && x > xs[k + 1]) k++;
      float mu = (x - xs[k]) / (xs[k + 1] - xs[k]);
      float m = (1.0f - cosf(mu * (float)M_PI)) * 0.5f;  // cosine ease
      y = ys[k] + (ys[k + 1] - ys[k]) * m;
    }
    s_curveY[s] = (int)y;
  }
}

// Centered small % readout for the scope ring.
static void charPct(int cx, int cy, float pct) {
  TFT_eSPI &t = display();
  char b[8];
  snprintf(b, sizeof(b), "%.0f", pct);
  t.setTextFont(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString(b, cx, cy - 1);
  t.setTextDatum(TL_DATUM);
}

// Shorten "Go 5h" -> "5h" for the cramped hero labels.
static const char *shortName(const char *n) {
  if ((n[0] == 'G' || n[0] == 'g') && (n[1] == 'O' || n[1] == 'o') && n[2] == ' ')
    return n + 3;
  return n;
}

static void drawHeroPanel(const QuotaState &q) {
  TFT_eSPI &t = display();
  const int pw = HERO_X1 - HERO_X0, ph = HERO_Y1 - HERO_Y0;

  // Panel + grid.
  t.drawRoundRect(HERO_X0, HERO_Y0, pw, ph, 4, COLOR_EDGE);
  t.fillRoundRect(HERO_X0 + 1, HERO_Y0 + 1, pw - 2, ph - 2, 3, COLOR_BG);
  for (int gx = HERO_X0 + 38; gx < HERO_X1 - 4; gx += 38)
    t.drawFastVLine(gx, HERO_Y0 + 2, ph - 4, COLOR_GRID);
  for (int gy = HERO_Y0 + 27; gy < HERO_Y1 - 4; gy += 27)
    t.drawFastHLine(HERO_X0 + 2, gy, pw - 4, COLOR_GRID);

  uint8_t n = q.oc_count;
  if (n == 0 || n > POOLS_MAX) return;
  float levels[POOLS_MAX];
  for (uint8_t i = 0; i < n; i++) levels[i] = q.oc[i].remaining_pct;
  sampleCurve(levels, n);

  // Gradient area fill: 6 stacked bands per column.
  for (int s = 0; s < HERO_SAMPLES; s++) {
    int x = HERO_X0 + s * HERO_STEP;
    int top = constrain(s_curveY[s], HERO_Y0 + 2, HERO_Y1 - 1);
    int h = HERO_Y1 - 1 - top;
    if (h <= 0) continue;
    for (uint8_t b = 0; b < 6; b++) {
      int bh = h / 6 + (b < (uint8_t)(h % 6) ? 1 : 0);
      if (bh <= 0) continue;
      int by = top + (h * b) / 6;
      t.fillRect(x, by, HERO_STEP, bh, lerp565(COLOR_WAVE_TOP, COLOR_BG, (uint8_t)(b * 255 / 5)));
    }
  }
  // Ice outline.
  for (int s = 0; s < HERO_SAMPLES - 1; s++) {
    int x0 = HERO_X0 + s * HERO_STEP;
    t.drawLine(x0, s_curveY[s], x0 + HERO_STEP, s_curveY[s + 1], COLOR_ICE);
  }

  // Markers + band labels.
  t.setTextFont(2);
#ifdef TV154
  // 240px: marker slots are 74px but labels are 60-86px, so neighbours
  // collide. Try below-marker first (v1 law), flip above on bottom-clip
  // OR intersection with an already placed label (see mock_tv154_render.py).
  int plx[POOLS_MAX], plx1[POOLS_MAX], ply[POOLS_MAX], ply1[POOLS_MAX];
  for (uint8_t i = 0; i < n; i++) {
    int mx = (int)(HERO_X0 + (i + 0.5f) * pw / n);
    int my = (int)((HERO_Y1 - 6) - constrain(levels[i], 0, 100) / 100.0f * (ph - 30));
    t.fillCircle(mx, my, 3, COLOR_BG);
    t.drawCircle(mx, my, 3, COLOR_ICE);
    char lbl[28];
    snprintf(lbl, sizeof(lbl), "%s %.1f%%", shortName(q.oc[i].name), levels[i]);
    int lw = t.textWidth(lbl);
    int lx = constrain(mx - lw / 2, HERO_X0 + 3, HERO_X1 - 3 - lw);
    int below = my + 7, above = my - 22;
    int ly = below;
    if (ly + 16 > HERO_Y1 - 3) ly = above;
    // Flip to whichever side avoids already-placed boxes.
    bool hit = false;
    for (uint8_t j = 0; j < i; j++) {
      if (lx < plx1[j] && lx + lw > plx[j] && ly < ply1[j] && ly + 16 > ply[j]) { hit = true; break; }
    }
    if (hit) {
      int alt = (ly == below) ? above : below;
      if (alt >= HERO_Y0 + 2 && alt + 16 <= HERO_Y1 - 2) ly = alt;
    }
    plx[i] = lx; plx1[i] = lx + lw; ply[i] = ly; ply1[i] = ly + 16;
    t.setTextColor(COLOR_TEXT, COLOR_BG);
    t.setCursor(lx, ly);
    t.print(lbl);
  }
#else
  for (uint8_t i = 0; i < n; i++) {
    int mx = (int)(HERO_X0 + (i + 0.5f) * pw / n);
    int my = (int)((HERO_Y1 - 6) - constrain(levels[i], 0, 100) / 100.0f * (ph - 30));
    t.fillCircle(mx, my, 3, COLOR_BG);
    t.drawCircle(mx, my, 3, COLOR_ICE);
    char lbl[28];
    snprintf(lbl, sizeof(lbl), "%s %.1f%%", shortName(q.oc[i].name), levels[i]);
    int lw = t.textWidth(lbl);
    int lx = constrain(mx - lw / 2, HERO_X0 + 3, HERO_X1 - 3 - lw);
    // Labels sit on the fill below their marker (white on blue reads well);
    // flip above only when the bottom would clip.
    int ly = my + 7;
    if (ly + 16 > HERO_Y1 - 3) ly = my - 22;
    t.setTextColor(COLOR_TEXT, COLOR_BG);
    t.setCursor(lx, ly);
    t.print(lbl);
  }
#endif
}

// Session rotator strip: conversation title + model between hero graph and
// bottom readout. Rotates one session per 10s render (matches main.cpp tick).
// Gap geometry: hero ends y=172, strip hairline y=210 → text at y=184..200.
static void sessionStrip(const QuotaState &q) {
  TFT_eSPI &t = display();
  tiny("SESSION", MARGIN, 176, COLOR_DIM, COLOR_BG);
  if (q.session_count == 0) {
    t.setTextFont(2);
    t.setTextColor(COLOR_DIM, COLOR_BG);
    t.setCursor(MARGIN, 186);
    t.print("-- idle --");
    return;
  }
  uint8_t idx = (uint8_t)((millis() / 10000UL) % q.session_count);
  const SessionState &s = q.sessions[idx];
  if (q.session_count > 1) {
    char pager[8];
    snprintf(pager, sizeof(pager), "%d/%d", idx + 1, q.session_count);
    t.setTextFont(1);
    int pw = t.textWidth(pager);
    t.setTextColor(COLOR_DIM, COLOR_BG);
    t.setCursor(LAYOUT_W - MARGIN - pw, 176);
    t.print(pager);
  }
  char line[SESSION_TITLE_MAX + SESSION_MODEL_MAX + 4];
  snprintf(line, sizeof(line), "%s - %s", s.title, s.model);
  t.setTextFont(2);
  while (strlen(line) > 1 && t.textWidth(line) > LAYOUT_W - MARGIN * 2) line[strlen(line) - 1] = '\0';
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor(MARGIN, 186);
  t.print(line);
}

void drawOverview(const QuotaState &q, bool netUp, bool serialMode) {
  display().fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!q.oc_connected || q.oc_count == 0) {
#ifdef TV154
    spaced("WAITING FOR BRIDGE", 20, 100, COLOR_DIM, COLOR_BG);
    tiny("CHECK WIFI + PORT 3847", 48, 124, COLOR_DIM, COLOR_BG);
#else
    spaced("WAITING FOR BRIDGE", 60, 100, COLOR_DIM, COLOR_BG);
    tiny("CHECK WIFI + PORT 3847", 88, 124, COLOR_DIM, COLOR_BG);
#endif
    readoutStrip(q);
    return;
  }
  drawHeroPanel(q);
  sessionStrip(q);
  readoutStrip(q);
}

void drawProviders(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!q.oc_connected || q.oc_count == 0) {
#ifdef TV154
    spaced("NO PROVIDERS", 56, 110, COLOR_DIM, COLOR_BG);
#else
    spaced("NO PROVIDERS", 96, 110, COLOR_DIM, COLOR_BG);
#endif
    return;
  }
  int y = HEADER_H + 10;
  // AUDIT H2: 4 pools must fit 240px. 3 rows use roomy y+=64; 4 rows switch
  // to condensed y+=50 (meter at y+38) so the 4th meter ends at ~236px.
  const bool condensed = (q.oc_count >= 4);
  const int yStep = condensed ? 50 : 64;
  const int meterY = condensed ? 38 : 46;
  for (uint8_t i = 0; i < q.oc_count && i < POOLS_MAX; i++) {
    const PoolState &p = q.oc[i];
    spaced(p.name, 12, y, q.oc_stale ? COLOR_AMBER : COLOR_DIM, COLOR_BG);
    centerPair(y + 2, p, LAYOUT_W - 12);
    meterBar(12, y + meterY, LAYOUT_W - 24, 10, p.remaining_pct, p.status);
    y += yStep;
  }
}

void drawScope(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  const int cx = 78, cy = 128, r = 50, th = 11;
  // Crosshair (vectorscope homage).
  t.drawFastHLine(cx - r - 8, cy, 2 * (r + 8), COLOR_EDGE);
  t.drawFastVLine(cx, cy - r - 8, 2 * (r + 8), COLOR_EDGE);
  // Tick dots around the ring (symmetric, no zero-point assumption).
  for (int a = 0; a < 360; a += 30) {
    float rad = a * (float)M_PI / 180.0f;
    int dx = (int)((r + 5) * sinf(rad));
    int dy = (int)(-(r + 5) * cosf(rad));
    t.fillCircle(cx + dx, cy + dy, 1, COLOR_DIM);
  }

  float m = minRemaining(q);
  uint8_t st = ST_OFFLINE;
  if (q.fresh && q.oc_connected) {
    st = ST_OK;
    for (uint8_t i = 0; i < q.oc_count; i++) st = max(st, q.oc[i].status);
  }
  // Background ring + progress arc.
  t.drawArc(cx, cy, r, r - th, 0, 360, COLOR_EDGE, COLOR_EDGE, false);
  if (q.fresh && q.oc_connected) {
    uint16_t col = statusColor(st);
    int end = (int)(constrain(m, 0, 100) / 100.0f * 360.0f);
    if (end > 0) t.drawArc(cx, cy, r, r - th, 0, (uint32_t)end, col, col, true);
  }
  // Provider dots on the ring.
  for (uint8_t i = 0; i < q.oc_count && i < 4; i++) {
    float rad = (i * 120.0f + 90.0f) * (float)M_PI / 180.0f;
    int dx = (int)(r * sinf(rad));
    int dy = (int)(-r * cosf(rad));
    t.fillCircle(cx + dx, cy + dy, 4, statusColor(q.oc[i].status));
    t.drawCircle(cx + dx, cy + dy, 4, COLOR_BG);
  }

  // Center readout, big: font4 fills the ring.
  char big[10];
  snprintf(big, sizeof(big), "%.0f", m);
  t.setTextFont(4);
  t.setTextColor(q.fresh ? COLOR_TEXT : COLOR_DIM, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString(big, cx, cy - 4);
  t.setTextDatum(TL_DATUM);
  tiny("MIN LEFT %", cx - 26, cy + 24, COLOR_DIM, COLOR_BG);

  // Right column: provider readouts.
  // AUDIT H2: cap at 3 rows on scope (firmware holds 4, bridge sends 4 max;
  // 4th row would collide with the hint line). H3: ASCII '-' separator.
  int y = 56;
  for (uint8_t i = 0; i < q.oc_count && i < 3; i++) {
    const PoolState &p = q.oc[i];
    char lbl[32];
    snprintf(lbl, sizeof(lbl), "P%d - %s", i + 1, p.name);
    spaced(lbl, 150, y, COLOR_DIM, COLOR_BG);
    rightPair(y + 14, p, LAYOUT_W - 12);
    y += 56;
  }
  tiny("TAP L/R - SCREENS", 150, LAYOUT_H - 18, COLOR_DIM, COLOR_BG);
}

void drawClock(const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  spaced("DESK CLOCK", 120, 44, COLOR_DIM, COLOR_BG);
  char hm[8] = "--:--";
  char date[24] = "";
  struct tm tm;
  if (getLocalTime(&tm, 0)) {
    snprintf(hm, sizeof(hm), "%02d:%02d", tm.tm_hour, tm.tm_min);
    snprintf(date, sizeof(date), "%04d-%02d-%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
  }
  t.setTextFont(6);
  t.setTextSize(2);
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString(hm, LAYOUT_W / 2, 108);
  t.setTextSize(1);
  t.setTextFont(2);
  t.setTextColor(COLOR_DIM, COLOR_BG);
  t.drawString(date, LAYOUT_W / 2, 166);
  t.setTextDatum(TL_DATUM);

  // Level bars homage: provider remaining as vertical gradient bars.
  int bx = 60;
  for (uint8_t i = 0; i < q.oc_count && i < 4; i++) {
    int h = (int)(constrain(q.oc[i].remaining_pct, 0, 100) / 100.0f * 34.0f);
    uint16_t col = statusColor(q.oc[i].status);
    t.drawRect(bx, 186, 14, 36, COLOR_EDGE);
    if (h > 0) t.fillRectVGradient(bx + 1, 186 + 35 - h, 12, h, col, darken(col));
    bx += 24;
  }
  const char *msg = q.oc_connected ? "SYNCED" : "WAITING FOR BRIDGE";
  spaced(msg, 200, 196, q.fresh ? COLOR_ICE : COLOR_DIM, COLOR_BG);
}

// ---- 05 ASK: OpenCode question with bottom touch buttons ----
// Geometry mirrors mock_hw_render.py:screen_ask() (ASK_BTNS_* boxes).
// 3-up: (8,172,97,48) (111,172,97,48) (214,172,98,48)
// 2-up: (8,172,149,48) (163,172,149,48)
// 1-up centered: (86,172,148,48)  -- AUDIT M6 (was left-aligned 97px)
// 4-grid: (8,124,149,44) (163,124,149,44) (8,174,149,44) (163,174,149,44)
// Single-option button box shared with askHit() in main.cpp - keep in sync.
#define ASK_SINGLE_X 86
#define ASK_SINGLE_W 148
#define ASK_SINGLE_Y 172
#define ASK_SINGLE_H 48
static void askButton(int x, int y, int w, int h, const char *label) {
  TFT_eSPI &t = display();
  t.drawRoundRect(x, y, w, h, 3, COLOR_EDGE);
  t.fillRoundRect(x + 1, y + 1, w - 2, h - 2, 2, COLOR_CARD);
  char b[ASK_OPT_LABEL_MAX + 1];
  strncpy(b, label, sizeof(b) - 1);
  b[sizeof(b) - 1] = '\0';
  t.setTextFont(2);
  while (strlen(b) > 1 && t.textWidth(b) > w - 12) b[strlen(b) - 1] = '\0';
  t.setTextColor(COLOR_TEXT, COLOR_CARD);
  t.setCursor(x + (w - t.textWidth(b)) / 2, y + (h - 16) / 2);
  t.print(b);
}

void drawAsk(const AskState &a, const QuotaState &q, bool netUp, bool serialMode) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  if (!a.pending) {
    spaced("NO QUESTION", 100, 110, COLOR_DIM, COLOR_BG);
    return;
  }

  // AUDIT M6: word-wrap question to 2 lines instead of mid-word chop.
  // Splits on spaces to fit 292px; second line truncated with ellipsis budget.
  auto drawWrapped = [&](int y0) {
    char line1[ASK_QUESTION_MAX + 1] = "";
    char line2[ASK_QUESTION_MAX + 1] = "";
    // Greedy fill line1.
    const char *p = a.question;
    char word[48];
    t.setTextFont(2);
    while (*p) {
      // skip spaces
      while (*p == ' ') p++;
      if (!*p) break;
      size_t wi = 0;
      while (*p && *p != ' ' && wi + 1 < sizeof(word)) word[wi++] = *p++;
      word[wi] = '\0';
      char cand[ASK_QUESTION_MAX + 1];
      if (!line1[0]) snprintf(cand, sizeof(cand), "%s", word);
      else snprintf(cand, sizeof(cand), "%s %s", line1, word);
      if (t.textWidth(cand) <= 292) {
        strncpy(line1, cand, sizeof(line1) - 1);
      } else {
        // overflow -> start line2 with this word + remainder (no mid-word cut)
        snprintf(line2, sizeof(line2), "%s", word);
        // append remaining words to line2 with truncation
        while (*p) {
          while (*p == ' ') p++;
          if (!*p) break;
          wi = 0;
          while (*p && *p != ' ' && wi + 1 < sizeof(word)) word[wi++] = *p++;
          word[wi] = '\0';
          char c2[ASK_QUESTION_MAX + 1];
          snprintf(c2, sizeof(c2), "%s %s", line2, word);
          if (t.textWidth(c2) > 292) break;  // drop the rest (292px budget)
          strncpy(line2, c2, sizeof(line2) - 1);
        }
        break;
      }
    }
    t.setTextColor(COLOR_TEXT, COLOR_BG);
    t.setCursor(13, y0);
    t.print(line1[0] ? line1 : a.question);
    if (line2[0]) {
      t.setCursor(13, y0 + 16);
      t.print(line2);
      return y0 + 32;
    }
    return y0 + 16;
  };

  if (a.count > 3) {
    // 4-option grid: compact card, no preview rows.
    t.drawRoundRect(8, 34, 304, 82, 4, COLOR_EDGE);
    t.fillRoundRect(9, 35, 302, 80, 3, COLOR_BG);
    tiny("OPENCODE ASKS", 13, 38, COLOR_DIM, COLOR_BG);
    drawWrapped(52);
    const int bx[4] = {8, 163, 8, 163}, by[4] = {124, 124, 174, 174};
    for (uint8_t i = 0; i < 4; i++) askButton(bx[i], by[i], 149, 44, a.opts[i].label);
  } else {
    t.drawRoundRect(8, 34, 304, 128, 4, COLOR_EDGE);
    t.fillRoundRect(9, 35, 302, 126, 3, COLOR_BG);
    tiny("OPENCODE ASKS", 13, 38, COLOR_DIM, COLOR_BG);
    int yEnd = drawWrapped(50);
    int detailY = (yEnd <= 66) ? 68 : 84;
    t.setTextFont(2);
    t.setTextColor(COLOR_DIM, COLOR_BG);
    t.setCursor(13, detailY);
    t.print(a.detail[0] ? a.detail : "tap an answer below");
    int hairY = detailY + 18;
    t.drawFastHLine(13, hairY, 294, COLOR_EDGE);
    int y = hairY + 6;
    for (uint8_t i = 0; i < a.count; i++) {
      char row[64];
      snprintf(row, sizeof(row), "%s - %s", a.opts[i].id, a.opts[i].label);
      while (strlen(row) > 1 && t.textWidth(row) > 292) row[strlen(row) - 1] = '\0';
      if (y + 18 > 168) break;  // never collide with button bar
      t.setCursor(13, y);
      t.setTextColor(COLOR_DIM, COLOR_BG);
      t.print(a.opts[i].id);
      t.setTextColor(COLOR_TEXT, COLOR_BG);
      t.print(" ");
      t.print(a.opts[i].label);
      y += 18;
    }
    if (a.count == 2) {
      askButton(8, 172, 149, 48, a.opts[0].label);
      askButton(163, 172, 149, 48, a.opts[1].label);
    } else if (a.count == 1) {
      askButton(ASK_SINGLE_X, ASK_SINGLE_Y, ASK_SINGLE_W, ASK_SINGLE_H, a.opts[0].label);
    } else {
      const int bx3[3] = {8, 111, 214}, bw3[3] = {97, 97, 98};
      for (uint8_t i = 0; i < a.count && i < 3; i++) askButton(bx3[i], 172, bw3[i], 48, a.opts[i].label);
    }
  }
  tiny("TAP TO ANSWER - BOOT = NEXT", 86, 226, COLOR_DIM, COLOR_BG);
}

// ---- END - WORK: latched ended-work notice (CYD 320x240) ----
// Geometry mirrors mock_endofwork_render.py:
//   header 0..28, tiny label y=38, title y=50, sub y=68, hairline y=88,
//   hero "END OF" y=96 / "WORK" y=146 (font6), button (8,196,304,32).
// Hero blinks TEXT white <-> ICE blue on each poll (blinkBlue). Any tap
// dismisses (handled in main.cpp); this screen never auto-exits.
void drawEndWork(const QuotaState &q, bool netUp, bool serialMode, bool blinkBlue) {
  TFT_eSPI &t = display();
  t.fillScreen(COLOR_BG);
  header(q, netUp, serialMode);

  t.setTextFont(1);
  tiny("ENDED WORK", (LAYOUT_W - (int)t.textWidth("ENDED WORK")) / 2, 38, COLOR_DIM, COLOR_BG);

  char title[ENDWORK_TITLE_MAX + 1];
  strncpy(title, q.has_endwork && q.endwork_title[0] ? q.endwork_title : "--", sizeof(title) - 1);
  title[sizeof(title) - 1] = '\0';
  t.setTextFont(2);
  while (strlen(title) > 1 && t.textWidth(title) > LAYOUT_W - 28) title[strlen(title) - 1] = '\0';
  t.setTextColor(COLOR_TEXT, COLOR_BG);
  t.setCursor((LAYOUT_W - t.textWidth(title)) / 2, 50);
  t.print(title);

  char sub[ENDWORK_MODEL_MAX + 1];
  strncpy(sub, q.has_endwork ? q.endwork_model : "", sizeof(sub) - 1);
  sub[sizeof(sub) - 1] = '\0';
  t.setTextFont(2);
  while (strlen(sub) > 1 && t.textWidth(sub) > LAYOUT_W - 28) sub[strlen(sub) - 1] = '\0';
  t.setTextColor(COLOR_DIM, COLOR_BG);
  if (sub[0]) {
    t.setCursor((LAYOUT_W - t.textWidth(sub)) / 2, 68);
    t.print(sub);
  }

  t.drawFastHLine(13, 88, LAYOUT_W - 26, COLOR_EDGE);

  uint16_t hero = blinkBlue ? COLOR_ICE : COLOR_TEXT;
  t.setTextFont(6);
  t.setTextSize(1);
  t.setTextColor(hero, COLOR_BG);
  t.setTextDatum(MC_DATUM);
  t.drawString("END OF", LAYOUT_W / 2, 119);
  t.drawString("WORK", LAYOUT_W / 2, 169);
  t.setTextDatum(TL_DATUM);

  // Dismiss hint: full-width bar, but ANY tap dismisses (main.cpp).
  t.drawRoundRect(8, 196, 304, 32, 3, COLOR_EDGE);
  t.fillRoundRect(9, 197, 302, 30, 2, COLOR_CARD);
  const char *hint = "TOUCH SCREEN TO DISMISS";
  t.setTextFont(2);
  t.setTextColor(COLOR_DIM, COLOR_CARD);
  t.setCursor((LAYOUT_W - t.textWidth(hint)) / 2, 196 + (32 - 16) / 2);
  t.print(hint);
}
