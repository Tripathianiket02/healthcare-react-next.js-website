//+------------------------------------------------------------------+
//|                                          SMC_Quant_EA_v3.0.mq5   |
//|        Quant Predictive Confluence EA (Real-Time Sync)           |
//|       Fix: Matches Indicator Bar 0 Execution (No Lag)            |
//+------------------------------------------------------------------+
#property copyright "Gemini AI"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group             "--- 0. Trade Settings ---"
input double            InpLotSize        = 0.01;     
input int               InpMagicNumber    = 888888;   
input int               InpSlippage       = 3;        
input bool              InpUseStopLoss    = true;     
input bool              InpUseTakeProfit  = true;    

input group             "--- 1. SMC Detection Settings ---"
input int               InpSwingLength    = 10;       
input double            InpFVGMinSize     = 0.5;      
input int               InpTrendPeriod    = 50;       

input group             "--- 2. Multi-Timeframe (MTF) ---"
input int               InpMTFMA          = 20;       
input bool              InpMTFM15         = true;     
input bool              InpMTFM30         = true;     
input bool              InpMTFH4          = true;     
input bool              InpMTFD1          = true;     

input group             "--- 3. Quantification Engine ---"
input int               InpMinConfidence  = 65;       
input double            InpATRMultiplier  = 1.5; // Adjusted slightly for volatility

input group             "--- 4. UI Settings ---"
input color             InpTextColor      = clrWhite; 
input color             InpBgColor        = C'30,30,30'; 
input int               InpFontSize       = 9;        

//--- Phase 1: Hierarchical CRT Settings
input group             "--- 5. D1 Gatekeeper ---"
input bool              InpUseD1Filter       = true;
input bool              InpD1DebugLogs       = true;

input group             "--- 6. CRT / H4 Setup ---"
input bool              InpUseCRT            = true;
input                   ENUM_TIMEFRAMES InpCRTTimeframe = PERIOD_H4;
input int               InpCRTValidity       = 2;      // candles
input double            InpMaxExcursionATR   = 0.5;    // ATR multiplier
input bool              InpCRTDebugLogs      = true;

//--- Structs
struct ConfluenceData {
   bool isTrendBullish;
   bool isSweepBullish;     
   bool isSweepBearish;     
   bool isDisplacementBullish;
   bool isFVGBullish;
   bool isRejectionBullish;
   int  mtfBullishScore;    
   string type;
   int confidence;
   string reasons;
   double price;
   double projected_stop;
   double projected_target;
   datetime time;
};

struct D1Context
{
   string   mode;       // "REVERSAL" or "CONTINUATION"
   string   direction;  // "BUY" or "SELL"
   bool     sweepHigh;
   bool     sweepLow;
   datetime lastBarTime;
};

struct CRTContext
{
   double   high;
   double   low;
   double   mid;
   string   bias;        // "BUY" or "SELL"
   double   excursion;   // price distance beyond range
   bool     excursionValid;
   datetime validUntil;
   datetime lastHTFBarTime;
   bool     active;
};


//--- Global Variables
CTrade         m_trade;
ConfluenceData currentSignal;
int            maHandle, atrHandle;
int            h_ma_m15, h_ma_m30, h_ma_h4, h_ma_d1;
datetime       lastTradeBarTime = 0; // CRITICAL: Prevents multiple trades on same bar

//--- CRT Global Variables
D1Context      d1;
CRTContext     crt;

// ATR handle for CRT timeframe
int atrHandleCRT = INVALID_HANDLE;
bool allowBuy = true;
bool allowSell = true;


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC); 
   m_trade.SetAsyncMode(false);

   // Indicators
   maHandle = iMA(_Symbol, _Period, InpTrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, _Period, 14);
   atrHandleCRT = iATR(_Symbol, InpCRTTimeframe, 14);
   
   h_ma_m15 = iMA(_Symbol, PERIOD_M15, InpMTFMA, 0, MODE_EMA, PRICE_CLOSE);
   h_ma_m30 = iMA(_Symbol, PERIOD_M30, InpMTFMA, 0, MODE_EMA, PRICE_CLOSE);
   h_ma_h4 = iMA(_Symbol, PERIOD_H4, InpMTFMA, 0, MODE_EMA, PRICE_CLOSE);
   h_ma_d1 = iMA(_Symbol, PERIOD_D1, InpMTFMA, 0, MODE_EMA, PRICE_CLOSE);
   
   if(maHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE) return(INIT_FAILED);
   if(atrHandleCRT == INVALID_HANDLE) return(INIT_FAILED);

   CreateDashboard();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "SMC_Quant_");
   ObjectsDeleteAll(0, "SMC_Arrow_");
   IndicatorRelease(maHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(h_ma_m15);
   IndicatorRelease(h_ma_m30);
   IndicatorRelease(h_ma_h4);
   IndicatorRelease(h_ma_d1);
   IndicatorRelease(atrHandleCRT);
}

//+------------------------------------------------------------------+
//| Expert tick function (Real-Time Execution)                       |
//+------------------------------------------------------------------+
void OnTick()
{
   UpdateD1Context();
   UpdateCRTContext();
   UpdateTradePermissions();
   // 1. Get Current Time
   datetime timeArr[];
   ArraySetAsSeries(timeArr, true);
   if(CopyTime(_Symbol, _Period, 0, 1, timeArr) < 0) return;
   
   datetime currentBarTime = timeArr[0];

   // 2. Run Logic on Bar 0 (Current Forming Bar)
   ProcessQuantLogic(0, currentBarTime);
}

//+------------------------------------------------------------------+
//| CRT UPDATE FUNCTION FOR H4 AND D!                                             |
//+------------------------------------------------------------------+
void UpdateD1Context()
{
   if(!InpUseD1Filter) return;

   datetime t[]; double h[], l[], c[], o[];
   ArraySetAsSeries(t,true); ArraySetAsSeries(h,true);
   ArraySetAsSeries(l,true); ArraySetAsSeries(c,true);
   ArraySetAsSeries(o,true);

   if(CopyTime(_Symbol, PERIOD_D1, 0, 3, t) < 3) return;
   if(CopyHigh(_Symbol, PERIOD_D1, 0, 3, h) < 3) return;
   if(CopyLow(_Symbol,  PERIOD_D1, 0, 3, l) < 3) return;
   if(CopyClose(_Symbol,PERIOD_D1, 0, 3, c) < 3) return;
   if(CopyOpen(_Symbol, PERIOD_D1, 0, 3, o) < 3) return;

   // update only on new closed D1 candle
   if(d1.lastBarTime == t[1]) return;
   d1.lastBarTime = t[1];

   // Sweep detection vs previous day
   d1.sweepHigh = (h[1] > h[2] && c[1] < h[2]);
   d1.sweepLow  = (l[1] < l[2] && c[1] > l[2]);

   if(d1.sweepHigh || d1.sweepLow)
   {
      d1.mode = "REVERSAL";
      d1.direction = d1.sweepHigh ? "SELL" : "BUY";
   }
   else
   {
      d1.mode = "CONTINUATION";
      d1.direction = (c[1] > o[1]) ? "BUY" : "SELL";
   }

   D1Log("Mode: " + d1.mode + " Dir: " + d1.direction +
         " SweepH:" + (string)d1.sweepHigh +
         " SweepL:" + (string)d1.sweepLow);
}

void UpdateCRTContext()
{
   if(!InpUseCRT) return;

   datetime t[]; double h[], l[], c[];
   ArraySetAsSeries(t,true); ArraySetAsSeries(h,true);
   ArraySetAsSeries(l,true); ArraySetAsSeries(c,true);

   if(CopyTime(_Symbol, InpCRTTimeframe, 0, 3, t) < 3) return;
   if(CopyHigh(_Symbol, InpCRTTimeframe, 0, 3, h) < 3) return;
   if(CopyLow(_Symbol,  InpCRTTimeframe, 0, 3, l) < 3) return;
   if(CopyClose(_Symbol,InpCRTTimeframe, 0, 3, c) < 3) return;

   // update only on new closed HTF candle
   if(crt.lastHTFBarTime == t[1])
   {
      CRTLog("Skip - same HTF candle");
      return;
   }
   crt.lastHTFBarTime = t[1];

   crt.high = h[1];
   crt.low  = l[1];
   crt.mid  = (crt.high + crt.low) / 2.0;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- Excursion ---
   double atrArr[1];
   if(CopyBuffer(atrHandleCRT, 0, 1, 1, atrArr) != 1) return;
   double maxExc = atrArr[0] * InpMaxExcursionATR;

   double excHigh = MathMax(0, price - crt.high);
   double excLow  = MathMax(0, crt.low - price);
   crt.excursion = MathMax(excHigh, excLow);
   crt.excursionValid = (crt.excursion <= maxExc);

   // --- Bias (simple Phase-1) ---
   crt.bias = (price < crt.mid) ? "BUY" : "SELL";

   // Expiration
   crt.validUntil = TimeCurrent() + (TFSeconds(InpCRTTimeframe) * InpCRTValidity);
   crt.active = true;

   CRTLog("Range H:" + P(crt.high) + " L:" + P(crt.low) + " Mid:" + P(crt.mid));
   CRTLog("Exc:" + P(crt.excursion) + " Max:" + P(maxExc) +
          " Valid:" + (string)crt.excursionValid);
   CRTLog("Bias:" + crt.bias + " ValidUntil:" + TimeToString(crt.validUntil));
}

//+------------------------------------------------------------------+
//| GATING FUNCTION LOGIC                                             |
//+------------------------------------------------------------------+
void UpdateTradePermissions()
{
   allowBuy = true;
   allowSell = true;

   // CRT must be active
   if(!crt.active || !crt.excursionValid)
   {
      allowBuy = false;
      allowSell = false;
      CRTLog("GATE: CRT inactive or invalid excursion");
      return;
   }

   // ONLY D1 decides direction
   if(d1.direction == "BUY")
   {
      allowSell = false;
   }
   else if(d1.direction == "SELL")
   {
      allowBuy = false;
   }

   CRTLog("GATE RESULT | Buy:" + (string)allowBuy + " Sell:" + (string)allowSell);
}

//+------------------------------------------------------------------+
//| Main Logic Processor                                             |
//+------------------------------------------------------------------+
void ProcessQuantLogic(int barIndex, datetime barTime)
{
   int calcBars = InpSwingLength + InpTrendPeriod + 5;
   
   double maArr[], atrArr[], open[], high[], low[], close[];
   datetime time[];
   
   // FORCE SERIES: Index 0 is NOW, Index 1 is Previous
   ArraySetAsSeries(maArr, true); ArraySetAsSeries(atrArr, true);
   ArraySetAsSeries(open, true); ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true); ArraySetAsSeries(close, true); ArraySetAsSeries(time, true);

   if(CopyBuffer(maHandle, 0, 0, calcBars, maArr) < 0) return;
   if(CopyBuffer(atrHandle, 0, 0, calcBars, atrArr) < 0) return;
   if(CopyOpen(_Symbol, _Period, 0, calcBars, open) < 0) return;
   if(CopyHigh(_Symbol, _Period, 0, calcBars, high) < 0) return;
   if(CopyLow(_Symbol, _Period, 0, calcBars, low) < 0) return;
   if(CopyClose(_Symbol, _Period, 0, calcBars, close) < 0) return;
   if(CopyTime(_Symbol, _Period, 0, calcBars, time) < 0) return;

   // Calculate on Bar 0 (Current Price Action)
   ConfluenceData signal = CalculateSignalData(barIndex, maArr, atrArr, time, open, high, low, close);
   currentSignal = signal; 
   
   // --- EXECUTION LOGIC ---
   if (signal.type != "NONE") 
   {
      // 1. Draw Visual Arrow immediately (Real-time feedback)
      DrawSignalArrow(signal.time, signal.type, signal.price, high[barIndex], low[barIndex]);
      
      // 2. Trade ONLY if we haven't traded this specific bar ID yet
      if(lastTradeBarTime != barTime)
      {
         bool opened = ExecuteTradeLogic(signal);
         if(opened) {
            lastTradeBarTime = barTime; // Lock this bar so we don't open 50 trades if signal flickers
         }
      }
   }
   
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Calculation Engine                                               |
//+------------------------------------------------------------------+
ConfluenceData CalculateSignalData(int i, const double &maArr[], const double &atrArr[],
                                   const datetime &time[], const double &open[], const double &high[], 
                                   const double &low[], const double &close[])
{
   ConfluenceData data;
   data.type = "NONE";
   data.confidence = 0;
   data.price = close[i];
   data.time = time[i];
   data.reasons = "";
   
   // 1. Trend
   bool trendBullish = close[i] > maArr[i];
   data.isTrendBullish = trendBullish;
   
   // 2. Liquidity Sweeps (Looking at Past bars 1 to N)
   double swingHigh = -1;
   double swingLow = 999999;
   
   int startSearch = i + 1;
   int endSearch = i + InpSwingLength;
   if(endSearch >= ArraySize(high)) endSearch = ArraySize(high) - 1;

   for(int k = startSearch; k <= endSearch; k++) {
      if(high[k] > swingHigh) swingHigh = high[k];
      if(low[k] < swingLow)   swingLow = low[k];
   }
   
   // Current Bar wicks below past Swing Low but closes above?
   bool sweepLow = (low[i] < swingLow && close[i] > swingLow); 
   bool sweepHigh = (high[i] > swingHigh && close[i] < swingHigh); 
   
   data.isSweepBullish = sweepLow;
   data.isSweepBearish = sweepHigh;
   
   // 3. Displacement
   double bodySize = MathAbs(close[i] - open[i]);
   bool displacement = bodySize > (atrArr[i] * 1.2);
   bool displacementBullish = displacement && (close[i] > open[i]);
   bool displacementBearish = displacement && (close[i] < open[i]);
   data.isDisplacementBullish = displacementBullish;
   
   // 4. FVG (Fair Value Gap)
   // Logic: Gap between Current Low and High of 2 bars ago
   bool fvgBullish = (low[i] > high[i+2]) && 
                     ((low[i] - high[i+2]) > InpFVGMinSize * _Point);
                     
   bool fvgBearish = (high[i] < low[i+2]) && 
                     ((low[i+2] - high[i]) > InpFVGMinSize * _Point);
   data.isFVGBullish = fvgBullish;
   
   // 5. Rejection
   double lowerWick = MathMin(open[i], close[i]) - low[i];
   double upperWick = high[i] - MathMax(open[i], close[i]);
   bool rejectionBullish = lowerWick > bodySize;
   bool rejectionBearish = upperWick > bodySize;
   data.isRejectionBullish = rejectionBullish;
   
   // 6. MTF Check
   int mtfBullishCount = 0;
   int mtfBearishCount = 0;
   mtfBullishCount += CheckMTFTrend(h_ma_m15, PERIOD_M15, InpMTFM15);
   mtfBullishCount += CheckMTFTrend(h_ma_m30, PERIOD_M30, InpMTFM30);
   mtfBullishCount += CheckMTFTrend(h_ma_h4, PERIOD_H4, InpMTFH4);
   mtfBullishCount += CheckMTFTrend(h_ma_d1, PERIOD_D1, InpMTFD1);
   mtfBearishCount = (InpMTFM15 + InpMTFM30 + InpMTFH4 + InpMTFD1) - mtfBullishCount;
   data.mtfBullishScore = mtfBullishCount;

   // Scoring Logic
   int buyScore = 0;
   if(trendBullish) buyScore += 20;
   if(sweepLow) buyScore += 35;
   if(displacementBullish) buyScore += 20;
   if(fvgBullish) buyScore += 15;
   if(rejectionBullish) buyScore += 10;
   if(mtfBullishCount >= 3) buyScore += 25;
   else if (mtfBullishCount >= 2) buyScore += 10;
   
   int sellScore = 0;
   if(!trendBullish) sellScore += 20;
   if(sweepHigh) sellScore += 35;
   if(displacementBearish) sellScore += 20;
   if(fvgBearish) sellScore += 15;
   if(rejectionBearish) sellScore += 10;
   if(mtfBearishCount >= 3) sellScore += 25;
   else if (mtfBearishCount >= 2) sellScore += 10;

   // --- THRESHOLD CHECK ---
   if (buyScore > sellScore && buyScore >= InpMinConfidence)
   {
      data.type = "BUY";
      data.confidence = buyScore;
      data.projected_target = swingHigh; 
      // Safe Stop Loss logic
      data.projected_stop = low[i] - (atrArr[i] * InpATRMultiplier * _Point);
   }
   else if (sellScore > buyScore && sellScore >= InpMinConfidence)
   {
      data.type = "SELL";
      data.confidence = sellScore;
      data.projected_target = swingLow;
      data.projected_stop = high[i] + (atrArr[i] * InpATRMultiplier * _Point);
   }
   //--- Phase-2 Gating ---
   if(data.type == "BUY" && !allowBuy)
   {
      data.type = "NONE";
      CRTLog("BUY blocked by Gate");
   }
   if(data.type == "SELL" && !allowSell)
   {
      data.type = "NONE";
      CRTLog("SELL blocked by Gate");
   }

   
   return data;
}

//+------------------------------------------------------------------+
//| Trade Execution                                                  |
//+------------------------------------------------------------------+
bool ExecuteTradeLogic(ConfluenceData &signal)
{
   // Check Existing Positions to prevent stacking
   bool hasBuy = false;
   bool hasSell = false;
   ulong buyTicket = 0;
   ulong sellTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { hasBuy = true; buyTicket = ticket; }
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) { hasSell = true; sellTicket = ticket; }
         }
      }
   }

   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double minGap = (stopLevel * _Point) + (spread * 2);

   // --- SELL LOGIC ---
   if(signal.type == "SELL")
   {
      // --- CLOSE BUY FIRST ---
      if(hasBuy)
      {
         if(!m_trade.PositionClose(buyTicket))
         {
            Print("!!! FAILED TO CLOSE BUY: ", GetLastError());
            return false;
         }
         else
         {
            Print(">>> BUY CLOSED FOR REVERSAL");
            Sleep(200); // small buffer
         }
      }
   
      if(hasSell) return false;
   
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = InpUseStopLoss ? signal.projected_stop : 0;
      double tp = InpUseTakeProfit ? signal.projected_target : 0;
   
      // --- VALIDATE SL ---
      if(InpUseStopLoss)
      {
         if(sl <= bid) sl = bid + minGap;
      }
   
      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);
   
      if(!m_trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "SMC Quant Sell"))
      {
         Print("!!! SELL FAILED: ", GetLastError());
         return false;
      }
   
      Print(">>> SELL EXECUTED");
      return true;
   }

   // --- BUY LOGIC ---
   else if(signal.type == "BUY")
   {
      // --- CLOSE SELL FIRST ---
      if(hasSell)
      {
         ResetLastError();
         if(!m_trade.PositionClose(sellTicket))
         {
            Print("!!! FAILED TO CLOSE SELL: ", GetLastError());
            return false;
         }
         else
         {
            Print(">>> SELL CLOSED FOR REVERSAL");
            Sleep(200); // small buffer to avoid trade context busy
         }
      }
   
      if(hasBuy) return false; // already have buy
   
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = InpUseStopLoss ? signal.projected_stop : 0;
      double tp = InpUseTakeProfit ? signal.projected_target : 0;
   
      // --- VALIDATE SL ---
      if(InpUseStopLoss)
      {
         // For BUY, SL must be BELOW price
         if(sl >= ask || sl == 0)
            sl = ask - minGap;
      }
   
      // Normalize
      if(sl > 0) sl = NormalizeDouble(sl, _Digits);
      if(tp > 0) tp = NormalizeDouble(tp, _Digits);
   
      ResetLastError();
      if(!m_trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "SMC Quant Buy"))
      {
         Print("!!! BUY FAILED: ", GetLastError());
         return false;
      }
   
      Print(">>> BUY EXECUTED");
      return true;
   }

   
   return false;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int CheckMTFTrend(int handle, ENUM_TIMEFRAMES period, bool checkEnabled) {
   if (!checkEnabled) return 0;
   double ma_val[1], close_val[1];
   if (CopyBuffer(handle, 0, 0, 1, ma_val) != 1) return 0; // Check Index 0 (Current) for MTF
   if (CopyClose(_Symbol, period, 0, 1, close_val) != 1) return 0;
   return (close_val[0] > ma_val[0]) ? 1 : 0;
}

void DrawSignalArrow(datetime time, string type, double price, double high, double low) {
   string name = "SMC_Arrow_" + TimeToString(time);
   if(ObjectFind(0, name) >= 0) return;
   
   if(type == "BUY") {
      ObjectCreate(0, name, OBJ_ARROW, 0, time, low);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 233);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrLimeGreen);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_TOP); 
   } else if(type == "SELL") {
      ObjectCreate(0, name, OBJ_ARROW, 0, time, high);
      ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 234);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 3);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
   }
}

//--- CRT Helpers

string P(double v){ 
   return DoubleToString(v, _Digits); 
}

void D1Log(string msg){ 
   if(InpD1DebugLogs) Print("[D1] ", msg); 
}

void CRTLog(string msg){ 
   if(InpCRTDebugLogs) Print("[CRT] ", msg); 
}

int TFSeconds(ENUM_TIMEFRAMES tf){ 
   return PeriodSeconds(tf); 
}

//+------------------------------------------------------------------+
//| Dashboard (Simplified)                                           |
//+------------------------------------------------------------------+
void CreateDashboard() {
   CreateLabel("L_Status", "Status: SCANNING BAR 0 (Real-Time)", 10, 20, clrLimeGreen, true);
   CreateLabel("L_LastSig", "Last Signal: None", 10, 40, clrWhite);
   CreateLabel("L_D1", "D1: -", 10, 60, clrYellow);
   CreateLabel("L_CRT", "CRT: -", 10, 80, clrWhite);
   CreateLabel("L_EXC", "EXC: -", 10,100, clrWhite);
   CreateLabel("L_GATE", "Gate: -", 10,120,clrAqua);
}
void UpdateDashboard() {
   string txt = (currentSignal.type != "NONE") ? currentSignal.type + " (" + IntegerToString(currentSignal.confidence) + "%)" : "Scanning...";
   ObjectSetString(0, "L_LastSig", OBJPROP_TEXT, "Last Signal: " + txt);
   string d1txt = d1.mode + " " + d1.direction;
   ObjectSetString(0,"L_D1",OBJPROP_TEXT,"D1: " + d1txt);
   
   string crttxt = crt.active ? crt.bias + " " + P(crt.low) + "-" + P(crt.high) : "OFF";
   ObjectSetString(0,"L_CRT",OBJPROP_TEXT,"CRT: " + crttxt);
   
   string exctxt = crt.active ? P(crt.excursion) + (crt.excursionValid?" OK":" X") : "-";
   ObjectSetString(0,"L_EXC",OBJPROP_TEXT,"EXC: " + exctxt);
   
   CRTLog("UI Sync | Bias:" + crt.bias + " Exc:" + P(crt.excursion));
   
   string gtxt = "B:" + (allowBuy?"1":"0") + " S:" + (allowSell?"1":"0");
   ObjectSetString(0,"L_GATE",OBJPROP_TEXT,"Gate: " + gtxt);


}
void CreateLabel(string name, string text, int x, int y, color c, bool bold=false) {
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, (datetime)0, 0.0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
}
