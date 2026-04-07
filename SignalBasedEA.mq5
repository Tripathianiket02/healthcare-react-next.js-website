//+------------------------------------------------------------------+
//|                                    LiquiditySweep_EA.mq5         |
//|        Pure Liquidity Sweep EA with MTF Confluence               |
//|        Trades ONLY on confirmed liquidity sweeps                 |
//+------------------------------------------------------------------+
#property copyright "Your Name"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group             "--- Trade Settings ---"
input double            InpLotSize        = 0.01;     
input int               InpMagicNumber    = 888888;   
input int               InpSlippage       = 3;        
input bool              InpUseStopLoss    = true;     
input bool              InpUseTakeProfit  = true;     
input double            InpRiskReward     = 2.0;      // RR ratio for TP

input group             "--- Liquidity Sweep Settings ---"
input int               InpSwingLength    = 20;       // Bars to look back for swing high/low
input double            InpSweepDepthPct  = 0.5;      // Min sweep depth as % of ATR
input int               InpATRPeriod      = 14;       // ATR period for volatility filter

input group             "--- Multi-Timeframe Confluence ---"
input bool              InpUseMTF         = true;     // Enable MTF confirmation
input ENUM_TIMEFRAMES   InpHTF1           = PERIOD_M15;
input ENUM_TIMEFRAMES   InpHTF2           = PERIOD_H1;
input ENUM_TIMEFRAMES   InpHTF3           = PERIOD_H4;
input int               InpMinHTFAlign    = 2;        // Min HTFs needed for confluence

input group             "--- Risk Management ---"
input double            InpMaxRiskPct     = 1.0;      // Max risk per trade (%)
input int               InpMaxTrades      = 1;        // Max simultaneous trades

input group             "--- UI Settings ---"
input color             InpTextColor      = clrWhite; 
input int               InpFontSize       = 10;       

//--- Structs
struct LiquiditySignal {
   string type;              // "BUY", "SELL", or "NONE"
   double price;             // Entry price
   double stopLoss;          // Stop loss level
   double takeProfit;        // Take profit level
   datetime time;            // Signal time
   int confidence;           // Confidence score (0-100)
   string reasons;           // Reasons for signal
   
   // Liquidity sweep details
   bool isBullishSweep;      // Swept lows and reclaimed
   bool isBearishSweep;      // Swept highs and rejected
   double sweptLevel;        // The liquidity level that was swept
   double sweepDepth;        // How deep the sweep went (in ATR)
   
   // MTF confluence
   int htfBullishCount;      // Number of HTFs bullish
   int htfBearishCount;      // Number of HTFs bearish
};

//--- Global Variables
CTrade         m_trade;
LiquiditySignal currentSignal;
int            atrHandle;
int            h_atf1_ma, h_atf2_ma, h_atf3_ma;  // MTF MA handles
datetime       lastTradeBarTime = 0;
double         g_point;                          // Normalized point value


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC); 
   m_trade.SetAsyncMode(false);
   
   // Get normalized point value
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   // Indicators - ATR for volatility measurement
   atrHandle = iATR(_Symbol, _Period, InpATRPeriod);
   
   // MTF Moving Averages for confluence
   h_atf1_ma = iMA(_Symbol, InpHTF1, 20, 0, MODE_EMA, PRICE_CLOSE);
   h_atf2_ma = iMA(_Symbol, InpHTF2, 20, 0, MODE_EMA, PRICE_CLOSE);
   h_atf3_ma = iMA(_Symbol, InpHTF3, 20, 0, MODE_EMA, PRICE_CLOSE);
   
   if(atrHandle == INVALID_HANDLE) return(INIT_FAILED);
   if(h_atf1_ma == INVALID_HANDLE || h_atf2_ma == INVALID_HANDLE || h_atf3_ma == INVALID_HANDLE) return(INIT_FAILED);

   CreateDashboard();
   Print("Liquidity Sweep EA Initialized Successfully");
   Print("Swing Length: ", InpSwingLength, " | Min HTF Align: ", InpMinHTFAlign);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "LS_Arrow_");
   ObjectsDeleteAll(0, "LS_Label_");
   IndicatorRelease(atrHandle);
   IndicatorRelease(h_atf1_ma);
   IndicatorRelease(h_atf2_ma);
   IndicatorRelease(h_atf3_ma);
   Print("EA Deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Get current bar time
   datetime timeArr[];
   ArraySetAsSeries(timeArr, true);
   if(CopyTime(_Symbol, _Period, 0, 1, timeArr) < 0) return;
   
   datetime currentBarTime = timeArr[0];
   
   // Process liquidity sweep logic on current bar
   ProcessLiquiditySweep(0, currentBarTime);
}

//+------------------------------------------------------------------+
//| Main Logic Processor                                             |
//+------------------------------------------------------------------+
void ProcessLiquiditySweep(int barIndex, datetime barTime)
{
   int calcBars = InpSwingLength + 10;
   
   double atrArr[], open[], high[], low[], close[];
   datetime time[];
   
   // FORCE SERIES: Index 0 is NOW
   ArraySetAsSeries(atrArr, true);
   ArraySetAsSeries(open, true); 
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true); 
   ArraySetAsSeries(close, true); 
   ArraySetAsSeries(time, true);

   if(CopyBuffer(atrHandle, 0, 0, calcBars, atrArr) < 0) return;
   if(CopyOpen(_Symbol, _Period, 0, calcBars, open) < 0) return;
   if(CopyHigh(_Symbol, _Period, 0, calcBars, high) < 0) return;
   if(CopyLow(_Symbol, _Period, 0, calcBars, low) < 0) return;
   if(CopyClose(_Symbol, _Period, 0, calcBars, close) < 0) return;
   if(CopyTime(_Symbol, _Period, 0, calcBars, time) < 0) return;

   // Calculate liquidity sweep signal
   LiquiditySignal signal = DetectLiquiditySweep(barIndex, atrArr, time, open, high, low, close);
   currentSignal = signal; 
   
   // --- EXECUTION LOGIC ---
   if (signal.type != "NONE") 
   {
      // Draw visual arrow immediately
      DrawSignalArrow(signal.time, signal.type, signal.price, high[barIndex], low[barIndex]);
      
      // Trade ONLY if we haven't traded this bar yet
      if(lastTradeBarTime != barTime)
      {
         bool opened = ExecuteTrade(signal);
         if(opened) {
            lastTradeBarTime = barTime;
            Print(">>> TRADE EXECUTED: ", signal.type, " | Confidence: ", signal.confidence, "%");
         }
      }
   }
   
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Liquidity Sweep Detection Engine                                 |
//+------------------------------------------------------------------+
LiquiditySignal DetectLiquiditySweep(int i, const double &atrArr[],
                                     const datetime &time[], 
                                     const double &open[], 
                                     const double &high[], 
                                     const double &low[], 
                                     const double &close[])
{
   LiquiditySignal signal;
   signal.type = "NONE";
   signal.confidence = 0;
   signal.price = close[i];
   signal.time = time[i];
   signal.reasons = "";
   signal.htfBullishCount = 0;
   signal.htfBearishCount = 0;
   
   // Get ATR value for volatility normalization
   double atr = atrArr[i];
   if(atr <= 0) return signal;
   
   // === STEP 1: IDENTIFY SWING HIGH/LOW ===
   double swingHigh = -1;
   double swingLow = 999999;
   
   // Look back InpSwingLength bars to find swing points
   int startSearch = i + 1;
   int endSearch = i + InpSwingLength;
   if(endSearch >= ArraySize(high)) endSearch = ArraySize(high) - 1;

   for(int k = startSearch; k <= endSearch; k++) {
      if(high[k] > swingHigh) swingHigh = high[k];
      if(low[k] < swingLow)   swingLow = low[k];
   }
   
   // === STEP 2: DETECT LIQUIDITY SWEEP ===
   // Bullish Sweep: Price sweeps below swing low but closes ABOVE it
   bool sweptLow = (low[i] < swingLow);
   bool reclaimedLow = (close[i] > swingLow);
   bool bullishSweep = sweptLow && reclaimedLow;
   
   // Bearish Sweep: Price sweeps above swing high but closes BELOW it
   bool sweptHigh = (high[i] > swingHigh);
   bool rejectedHigh = (close[i] < swingHigh);
   bool bearishSweep = sweptHigh && rejectedHigh;
   
   signal.isBullishSweep = bullishSweep;
   signal.isBearishSweep = bearishSweep;
   
   // Calculate sweep depth (how far did price go beyond the level)
   if(bullishSweep) {
      signal.sweptLevel = swingLow;
      signal.sweepDepth = (swingLow - low[i]) / atr;
   } else if(bearishSweep) {
      signal.sweptLevel = swingHigh;
      signal.sweepDepth = (high[i] - swingHigh) / atr;
   }
   
   // Minimum sweep depth filter
   if(signal.sweepDepth < InpSweepDepthPct) {
      // Not a significant sweep
      if(!bullishSweep && !bearishSweep) return signal;
   }
   
   // === STEP 3: MULTI-TIMEFRAME CONFLUENCE ===
   if(InpUseMTF) {
      signal.htfBullishCount = CheckMTFConfluence();
      signal.htfBearishCount = 3 - signal.htfBullishCount;  // Total 3 HTFs
   }
   
   // === STEP 4: SCORING AND SIGNAL GENERATION ===
   int buyScore = 0;
   int sellScore = 0;
   
   // Bullish sweep scoring
   if(bullishSweep) {
      buyScore += 40;  // Base score for sweep
      
      // Add score for sweep depth
      if(signal.sweepDepth >= 1.0) buyScore += 15;
      else if(signal.sweepDepth >= 0.5) buyScore += 10;
      
      // MTF confluence bonus
      if(signal.htfBullishCount >= InpMinHTFAlign) buyScore += 30;
      else if(signal.htfBullishCount >= 1) buyScore += 15;
      
      signal.reasons = "Bullish Sweep";
      if(signal.sweepDepth >= 0.5) signal.reasons += " (Deep)";
      if(signal.htfBullishCount >= InpMinHTFAlign) signal.reasons += " +MTF";
   }
   
   // Bearish sweep scoring
   if(bearishSweep) {
      sellScore += 40;  // Base score for sweep
      
      // Add score for sweep depth
      if(signal.sweepDepth >= 1.0) sellScore += 15;
      else if(signal.sweepDepth >= 0.5) sellScore += 10;
      
      // MTF confluence bonus
      if(signal.htfBearishCount >= InpMinHTFAlign) sellScore += 30;
      else if(signal.htfBearishCount >= 1) sellScore += 15;
      
      signal.reasons = "Bearish Sweep";
      if(signal.sweepDepth >= 0.5) signal.reasons += " (Deep)";
      if(signal.htfBearishCount >= InpMinHTFAlign) signal.reasons += " +MTF";
   }
   
   // Determine final signal
   if(buyScore > sellScore && buyScore >= 50) {
      signal.type = "BUY";
      signal.confidence = MathMin(buyScore, 100);
      
      // Calculate SL below the sweep low
      signal.stopLoss = low[i] - (atr * 0.5);
      
      // Calculate TP based on RR ratio
      double risk = signal.price - signal.stopLoss;
      signal.takeProfit = signal.price + (risk * InpRiskReward);
      
   } else if(sellScore > buyScore && sellScore >= 50) {
      signal.type = "SELL";
      signal.confidence = MathMin(sellScore, 100);
      
      // Calculate SL above the sweep high
      signal.stopLoss = high[i] + (atr * 0.5);
      
      // Calculate TP based on RR ratio
      double risk = signal.stopLoss - signal.price;
      signal.takeProfit = signal.price - (risk * InpRiskReward);
   }
   
   return signal;
}

//+------------------------------------------------------------------+
//| MTF Confluence Check                                             |
//+------------------------------------------------------------------+
int CheckMTFConfluence()
{
   int bullishCount = 0;
   double maVal[1], closeVal[1];
   
   // Check HTF1
   if(CopyBuffer(h_atf1_ma, 0, 0, 1, maVal) == 1 && 
      CopyClose(_Symbol, InpHTF1, 0, 1, closeVal) == 1) {
      if(closeVal[0] > maVal[0]) bullishCount++;
   }
   
   // Check HTF2
   if(CopyBuffer(h_atf2_ma, 0, 0, 1, maVal) == 1 && 
      CopyClose(_Symbol, InpHTF2, 0, 1, closeVal) == 1) {
      if(closeVal[0] > maVal[0]) bullishCount++;
   }
   
   // Check HTF3
   if(CopyBuffer(h_atf3_ma, 0, 0, 1, maVal) == 1 && 
      CopyClose(_Symbol, InpHTF3, 0, 1, closeVal) == 1) {
      if(closeVal[0] > maVal[0]) bullishCount++;
   }
   
   return bullishCount;
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
