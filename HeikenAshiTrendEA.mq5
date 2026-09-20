//+------------------------------------------------------------------+
//|                                          HeikenAshiTrendEA.mq5   |
//| Heiken Ashi trend following EA with daily profit/loss protection |
//+------------------------------------------------------------------+
#property copyright "NadirAliOfficial"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs -----------------------------------------------------------

input group "Heiken Ashi Signal"
input ENUM_TIMEFRAMES HA_Timeframe        = PERIOD_M15;   // Heiken Ashi timeframe
input int             HA_LookbackBars     = 300;          // Bars used to build HA series

input group "Risk Management"
input double          LotSize             = 0.10;         // Fixed lot size
input bool            UseStopLoss         = true;          // Enable Stop Loss
input int             StopLossPoints      = 500;           // Stop Loss, points
input bool            UseTakeProfit       = true;          // Enable Take Profit
input int             TakeProfitPoints    = 1000;          // Take Profit, points
input int             MaxSlippagePoints   = 30;             // Max slippage, points
input bool            UseSpreadFilter     = true;           // Enable max spread filter
input int             MaxSpreadPoints     = 300;            // Max spread, points
input long            MagicNumber         = 88123400;       // Magic number

input group "Trading Time & Daily Protection"
input string          StartTime           = "00:00";        // Trading start time (HH:MM, server time)
input string          StopTime            = "23:59";        // Trading stop time (HH:MM, server time)
input bool            UseDailyProfitLimit = true;            // Enable daily profit % target
input double          DailyProfitPercent  = 3.0;             // Daily profit target, % of daily start capital
input bool            UseDailyLossLimit   = true;            // Enable daily loss % limit
input double          DailyLossPercent    = 2.0;             // Daily loss limit, % of daily start capital
input bool            UseEquityForDaily   = true;            // Use equity (true) or balance (false) for daily start capital

input group "Dashboard"
input bool            ShowDashboard       = true;            // Show on chart dashboard
input int             DashboardX          = 15;              // Dashboard X offset
input int             DashboardY          = 20;              // Dashboard Y offset

//--- Globals ------------------------------------------------------------

CTrade         trade;
datetime       g_lastHaBarTime   = 0;
datetime       g_currentDay      = 0;
double         g_dailyStartCap   = 0.0;
bool           g_dailyLimitHit   = false;
string         g_status          = "Waiting";
string         g_lastDirection   = "None";

#define DASH_PREFIX "HAEA_"

//+------------------------------------------------------------------+
//| Helpers: trading time window                                      |
//+------------------------------------------------------------------+
bool ParseHHMM(const string s, int &hour, int &minute)
{
   string parts[];
   int n = StringSplit(s, ':', parts);
   if(n < 2) return false;
   hour   = (int)StringToInteger(parts[0]);
   minute = (int)StringToInteger(parts[1]);
   return true;
}

bool IsWithinTradingWindow(datetime t)
{
   int sh, sm, eh, em;
   if(!ParseHHMM(StartTime, sh, sm) || !ParseHHMM(StopTime, eh, em))
      return true; // fail open if misconfigured, do not silently block trading

   MqlDateTime dt;
   TimeToStruct(t, dt);
   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = sh * 60 + sm;
   int stopMinutes  = eh * 60 + em;

   if(startMinutes <= stopMinutes)
      return (nowMinutes >= startMinutes && nowMinutes <= stopMinutes);
   // window wraps past midnight
   return (nowMinutes >= startMinutes || nowMinutes <= stopMinutes);
}

datetime StartOfDay(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Daily capital tracking and limit checks                           |
//+------------------------------------------------------------------+
void UpdateDailyState()
{
   datetime today = StartOfDay(TimeCurrent());
   int sh, sm;
   ParseHHMM(StartTime, sh, sm);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMinutes   = dt.hour * 60 + dt.min;
   int startMinutes = sh * 60 + sm;

   bool newDay = (today != g_currentDay);
   bool pastStart = (nowMinutes >= startMinutes);

   if(newDay && pastStart)
   {
      g_currentDay    = today;
      g_dailyStartCap = UseEquityForDaily ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyLimitHit = false;
   }
   else if(g_dailyStartCap <= 0.0)
   {
      // first run of the EA, mid session
      g_currentDay    = today;
      g_dailyStartCap = UseEquityForDaily ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

double GetDailyPL()
{
   if(g_dailyStartCap <= 0.0) return 0.0;
   double current = AccountInfoDouble(ACCOUNT_EQUITY);
   return current - g_dailyStartCap;
}

double GetDailyPLPercent()
{
   if(g_dailyStartCap <= 0.0) return 0.0;
   return (GetDailyPL() / g_dailyStartCap) * 100.0;
}

bool DailyLimitBreached()
{
   double plPercent = GetDailyPLPercent();
   if(UseDailyProfitLimit && plPercent >= DailyProfitPercent) return true;
   if(UseDailyLossLimit  && plPercent <= -DailyLossPercent)  return true;
   return false;
}

//+------------------------------------------------------------------+
//| Position helpers, scoped to this EA's magic number and symbol     |
//+------------------------------------------------------------------+
bool GetOwnPosition(ulong &ticket, long &posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      ticket  = t;
      posType = PositionGetInteger(POSITION_TYPE);
      return true;
   }
   ticket = 0;
   posType = -1;
   return false;
}

void CloseOwnPosition()
{
   ulong ticket; long posType;
   if(GetOwnPosition(ticket, posType))
      trade.PositionClose(ticket, MaxSlippagePoints);
}

void CloseAllOwnPositionsForDailyStop()
{
   ulong ticket; long posType;
   if(GetOwnPosition(ticket, posType))
      trade.PositionClose(ticket, MaxSlippagePoints);
}

//+------------------------------------------------------------------+
//| Spread filter                                                     |
//+------------------------------------------------------------------+
bool SpreadOk()
{
   if(!UseSpreadFilter) return true;
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPoints <= MaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Heiken Ashi computation                                           |
//+------------------------------------------------------------------+
// Returns true and fills haOpen/haClose for the last CLOSED HA bar (index 1
// on the HA timeframe, i.e. the previous fully formed bar).
bool GetLastClosedHeikenAshi(double &haOpenOut, double &haCloseOut, datetime &barTimeOut)
{
   MqlRates rates[];
   int need = MathMax(HA_LookbackBars, 10);
   int copied = CopyRates(_Symbol, HA_Timeframe, 0, need, rates);
   if(copied < 5) return false;

   // CopyRates returns oldest -> newest with index 0 oldest by default when
   // using the (symbol, timeframe, start, count) overload; verify order.
   ArraySetAsSeries(rates, false); // ensure ascending time order, index 0 = oldest

   int n = ArraySize(rates);
   double haOpen[], haClose[];
   ArrayResize(haOpen, n);
   ArrayResize(haClose, n);

   haOpen[0]  = (rates[0].open + rates[0].close) / 2.0;
   haClose[0] = (rates[0].open + rates[0].high + rates[0].low + rates[0].close) / 4.0;

   for(int i = 1; i < n; i++)
   {
      haClose[i] = (rates[i].open + rates[i].high + rates[i].low + rates[i].close) / 4.0;
      haOpen[i]  = (haOpen[i-1] + haClose[i-1]) / 2.0;
   }

   // rates[n-1] is the currently forming bar; the last CLOSED HA bar is n-2.
   int lastClosedIdx = n - 2;
   if(lastClosedIdx < 0) return false;

   haOpenOut  = haOpen[lastClosedIdx];
   haCloseOut = haClose[lastClosedIdx];
   barTimeOut = rates[lastClosedIdx].time;
   return true;
}

//+------------------------------------------------------------------+
//| Trade execution                                                    |
//+------------------------------------------------------------------+
void OpenPosition(bool buy)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   double price = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = 0.0, tp = 0.0;
   if(UseStopLoss)
      sl = buy ? price - StopLossPoints * point : price + StopLossPoints * point;
   if(UseTakeProfit)
      tp = buy ? price + TakeProfitPoints * point : price - TakeProfitPoints * point;

   trade.SetDeviationInPoints(MaxSlippagePoints);
   trade.SetExpertMagicNumber(MagicNumber);

   bool sent;
   if(buy)
      sent = trade.Buy(LotSize, _Symbol, price, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits));
   else
      sent = trade.Sell(LotSize, _Symbol, price, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits));

   if(!sent)
      Print("HeikenAshiTrendEA: order send failed, retcode=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Signal processing                                                  |
//+------------------------------------------------------------------+
void ProcessSignal()
{
   double haOpen, haClose;
   datetime barTime;
   if(!GetLastClosedHeikenAshi(haOpen, haClose, barTime))
      return;

   if(barTime == g_lastHaBarTime)
      return; // already handled this closed bar

   g_lastHaBarTime = barTime;

   bool isGreen = haClose > haOpen;
   bool isRed   = haClose < haOpen;
   if(!isGreen && !isRed)
      return; // doji, no signal

   if(!IsWithinTradingWindow(TimeCurrent()) || g_dailyLimitHit)
   {
      g_status = g_dailyLimitHit ? "Daily limit reached" : "Outside trading hours";
      return;
   }

   if(!SpreadOk())
   {
      g_status = "Blocked: spread too high";
      return;
   }

   ulong ticket; long posType;
   bool hasPosition = GetOwnPosition(ticket, posType);

   string wantDirection = isGreen ? "BUY" : "SELL";

   if(hasPosition)
   {
      bool posIsBuy = (posType == POSITION_TYPE_BUY);
      bool sameDirection = (posIsBuy && isGreen) || (!posIsBuy && isRed);
      if(sameDirection)
      {
         g_status = "Holding " + wantDirection + " (duplicate signal ignored)";
         return; // duplicate trade protection
      }
      // direction flipped: close current, open opposite
      CloseOwnPosition();
      OpenPosition(isGreen);
   }
   else
   {
      OpenPosition(isGreen);
   }

   g_lastDirection = wantDirection;
   g_status = "Signal: " + wantDirection;
}

//+------------------------------------------------------------------+
//| Dashboard                                                          |
//+------------------------------------------------------------------+
void DashLabel(string name, string text, int x, int y, color clr)
{
   string obj = DASH_PREFIX + name;
   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, obj, OBJPROP_FONT, "Consolas");
   }
   ObjectSetString(0, obj, OBJPROP_TEXT, text);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}

void UpdateDashboard()
{
   if(!ShowDashboard) return;

   ulong ticket; long posType;
   bool hasPosition = GetOwnPosition(ticket, posType);
   string direction = hasPosition ? (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") : "FLAT";
   double lots = hasPosition ? PositionGetDouble(POSITION_VOLUME) : 0.0;
   double floatingPL = hasPosition ? PositionGetDouble(POSITION_PROFIT) : 0.0;
   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   int y = DashboardY;
   int step = 16;

   DashLabel("title", "Heiken Ashi Trend EA", DashboardX, y, clrWhite); y += step + 4;
   DashLabel("status", "Status: " + g_status, DashboardX, y, clrSilver); y += step;
   DashLabel("direction", "Direction: " + direction, DashboardX, y, direction == "BUY" ? clrLime : (direction == "SELL" ? clrTomato : clrSilver)); y += step;
   DashLabel("trade", "Lot size: " + DoubleToString(lots, 2), DashboardX, y, clrSilver); y += step;
   DashLabel("pl", "Floating P/L: " + DoubleToString(floatingPL, 2), DashboardX, y, floatingPL >= 0 ? clrLime : clrTomato); y += step;
   DashLabel("dailypl", "Daily P/L: " + DoubleToString(GetDailyPL(), 2) + " (" + DoubleToString(GetDailyPLPercent(), 2) + "%)", DashboardX, y, GetDailyPL() >= 0 ? clrLime : clrTomato); y += step;
   DashLabel("dailycap", "Daily start capital: " + DoubleToString(g_dailyStartCap, 2), DashboardX, y, clrSilver); y += step;
   DashLabel("spread", "Spread: " + DoubleToString(spreadPts, 0) + " pts", DashboardX, y, clrSilver); y += step;
   DashLabel("time", "Trading window: " + StartTime + " - " + StopTime, DashboardX, y, clrSilver); y += step;
   DashLabel("limits", "Daily target/limit: +" + DoubleToString(DailyProfitPercent, 1) + "% / -" + DoubleToString(DailyLossPercent, 1) + "%", DashboardX, y, clrSilver);
}

void RemoveDashboard()
{
   ObjectsDeleteAll(0, DASH_PREFIX);
}

//+------------------------------------------------------------------+
//| Expert lifecycle                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   g_currentDay    = 0;
   g_dailyStartCap = 0.0;
   g_dailyLimitHit = false;
   g_lastHaBarTime = 0;
   UpdateDailyState();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   RemoveDashboard();
}

void OnTick()
{
   UpdateDailyState();

   if(!g_dailyLimitHit && DailyLimitBreached())
   {
      g_dailyLimitHit = true;
      CloseAllOwnPositionsForDailyStop();
      g_status = "Daily limit reached, trading stopped";
   }

   if(!g_dailyLimitHit)
      ProcessSignal();

   UpdateDashboard();
}
//+------------------------------------------------------------------+
