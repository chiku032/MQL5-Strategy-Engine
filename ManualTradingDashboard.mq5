//+------------------------------------------------------------------+
//|  ManualTradingDashboard.mq5                                      |
//|  Professional Manual Trading Dashboard EA  v6.0                  |
//|  MANUAL trade execution dashboard ONLY.                          |
//|  No signal generation. No auto-trading. No strategy logic.       |
//+------------------------------------------------------------------+
#property copyright   "Manual Trading Dashboard"
#property version     "6.60"
#property description "Professional Manual Trading Dashboard - No Auto Trading"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "=== DEFAULTS (all editable live on dashboard) ==="
input double InpTradeRisk        = 1000.0;
input double InpAllowedLeverage  = 15.0;
input double InpMaxMargin        = 5000.0;
input int    InpSLPips           = 300;
input int    InpTPPips           = 900;
input int    InpMaxSpread        = 50;
input int    InpSplitTrades      = 1;
input int    InpMaxPositions     = 2;

input group "=== ORDER SETTINGS ==="
input int    InpMagicNumber      = 123456;
input string InpTradeComment     = "MTD";

input group "=== PANEL POSITION ==="
input int    InpPanelX           = 10;
input int    InpPanelY           = 30;

//+------------------------------------------------------------------+
//| ENUMS                                                             |
//|                                                                   |
//| KEY DESIGN: direction (Buy/Sell) is encoded in the order type.  |
//| This eliminates ALL ambiguity in CalcSLTP and ExecuteTrade.     |
//+------------------------------------------------------------------+
enum ENUM_DASH_ORDERTYPE
{
   OTYPE_MARKET_BUY  = 0,  // Market Buy
   OTYPE_MARKET_SELL = 1,  // Market Sell
   OTYPE_BUY_LIMIT   = 2,
   OTYPE_SELL_LIMIT  = 3,
   OTYPE_BUY_STOP    = 4,
   OTYPE_SELL_STOP   = 5
};
enum ENUM_SL_MODE { SL_PIPS=0, SL_PRICE=1 };
enum ENUM_TP_MODE { TP_PIPS=0, TP_PRICE=1 };

// Helper: is the given order type a Buy direction?
bool OrderIsBuy(ENUM_DASH_ORDERTYPE t)
{
   return (t==OTYPE_MARKET_BUY || t==OTYPE_BUY_LIMIT || t==OTYPE_BUY_STOP);
}

//+------------------------------------------------------------------+
//| DASHBOARD STATE                                                   |
//+------------------------------------------------------------------+
struct DashboardState
{
   // Account
   double accountBalance, accountEquity, freeMargin, usedMargin;
   int    accountLeverage;
   // Symbol specs (all from broker, no hardcoded values)
   double ask, bid, currentSpread;
   double contractSize, tickSize, tickValue;
   int    digits;
   double volumeStep, minLot, maxLot;
   // User risk inputs
   double tradeRisk, allowedLeverage, maxMarginAllowed;
   int    maxSpread, splitCount, maxPositions;
   // SL/TP input mode
   ENUM_SL_MODE slMode; int slPips; double slPrice;
   ENUM_TP_MODE tpMode; int tpPips; double tpPrice;
   double pendingPrice;
   // Order type (encodes direction)
   ENUM_DASH_ORDERTYPE orderType;
   // Calculated outputs
   double entryPrice;       // computed entry for display
   double computedSL;       // computed SL price
   double computedTP;       // computed TP price
   double calculatedLotSize;
   double maxLotByLeverage, maxLotByMargin, maxAllowedLot;
   double marginRequired;
   double riskRewardRatio;
   double marginAlreadyUsed, remainingMarginAvail;
   // News
   string newsStr[3];
   datetime newsTime[3];
   bool     newsBlocking;
   string   newsBlockMsg;
   // Countdown / upcoming display (filled by CheckNewsBlocking)
   string   newsNextLabel;   // e.g. "Next News: 18:00 IST (Event 2)"
   string   newsCountdown;   // e.g. "Trading Resumes In: 08m 25s"
   bool     newsUpcoming;    // true when a news event is within 60 min but not yet blocking
   // Validation
   bool   spreadOk, leverageOk, positionLimitOk;
   bool   isValid;
   string validationMessage;
   // Selected trade
   ulong  selectedTicket;
   bool   selectedIsPending;
};

DashboardState g_state;

//+------------------------------------------------------------------+
//| GLOBAL OBJECTS                                                    |
//+------------------------------------------------------------------+
CTrade        g_trade;
CPositionInfo g_position;
COrderInfo    g_order;

string g_prefix = "MTD_";
string g_allObjects[];

//+------------------------------------------------------------------+
//| ZOOM                                                              |
//+------------------------------------------------------------------+
double g_zoom = 1.0;

const int BASE_PNL_W  = 980;
const int BASE_COL_AW = 460;
const int BASE_COL_BX = 468;
const int BASE_COL_BW = 508;
const int BASE_EDIT_H = 17;
const int BASE_BTN_H  = 22;
const int BASE_ROW_H  = 15;

int PNL_W()  { return (int)MathRound(BASE_PNL_W *g_zoom); }
int COL_AW() { return (int)MathRound(BASE_COL_AW*g_zoom); }
int COL_BX() { return (int)MathRound(BASE_COL_BX*g_zoom); }
int COL_BW() { return (int)MathRound(BASE_COL_BW*g_zoom); }
int EDIT_H() { return (int)MathRound(BASE_EDIT_H*g_zoom); }
int BTN_H()  { return (int)MathRound(BASE_BTN_H *g_zoom); }
int ROW_H()  { return (int)MathRound(BASE_ROW_H *g_zoom); }
int S(int v) { return (int)MathRound(v*g_zoom); }
int FS(int b){ return MathMax(6,(int)MathRound(b*g_zoom)); }

int PNL_X, PNL_Y;

bool   g_dropdownOpen = false;
// 6 order types now
string g_ddLabels[] = {"Market Buy","Market Sell","Buy Limit","Sell Limit","Buy Stop","Sell Stop"};

const int NEWS_BLOCK_MINS    = 10;
const int NEWS_TZ_OFFSET_SEC = 19800;  // IST = UTC+05:30

color CLR_BG      = C'16,16,26';
color CLR_HDR     = C'26,26,44';
color CLR_SECT    = C'21,21,34';
color CLR_BUY     = C'0,160,0';
color CLR_SELL    = C'190,0,0';
color CLR_WARN    = C'200,160,0';
color CLR_INFO    = C'170,170,190';
color CLR_LABEL   = C'110,110,135';
color CLR_VALUE   = C'235,235,252';
color CLR_BORDER  = C'50,50,80';
color CLR_VALID   = C'0,180,80';
color CLR_INVALID = C'200,40,40';
color CLR_EDITBG  = C'8,8,18';
color CLR_BTN     = C'36,36,60';
color CLR_KILL    = C'150,0,0';
color CLR_DDOPEN  = C'52,52,98';
color CLR_SELBTN  = C'75,75,0';
color CLR_WARN2   = C'180,120,0';
color CLR_NEWS    = C'170,0,170';

//+------------------------------------------------------------------+
//| OBJECT TRACKING                                                   |
//+------------------------------------------------------------------+
void TrackObject(string name)
{
   int sz=ArraySize(g_allObjects);
   ArrayResize(g_allObjects,sz+1);
   g_allObjects[sz]=name;
}

//+------------------------------------------------------------------+
//| PRIMITIVES                                                        |
//+------------------------------------------------------------------+
void CreateLabel(string name,int x,int y,string txt,color clr,
                 int fs=8,string font="Arial",
                 ENUM_ANCHOR_POINT anc=ANCHOR_LEFT_UPPER)
{
   if(ObjectFind(0,name)<0){ ObjectCreate(0,name,OBJ_LABEL,0,0,0); TrackObject(name); }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetString (0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anc);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1);
}
void CreateRect(string name,int x,int y,int w,int h,
                color bg,color border=clrNONE,int bw=0)
{
   if(ObjectFind(0,name)<0){ ObjectCreate(0,name,OBJ_RECTANGLE_LABEL,0,0,0); TrackObject(name); }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,(border==clrNONE)?bg:border);
   ObjectSetInteger(0,name,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,bw);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,0);
}
// ZORDER=10: always on top → reliable single click
void CreateButton(string name,int x,int y,int w,int h,
                  string txt,color bg,color tc,int fs=8,string font="Arial Bold")
{
   if(ObjectFind(0,name)<0){ ObjectCreate(0,name,OBJ_BUTTON,0,0,0); TrackObject(name); }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,tc);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetString (0,name,OBJPROP_FONT,font);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,10);
}
void CreateEdit(string name,int x,int y,int w,int h,
                string txt,color bg=0,color tc=0,int fs=8)
{
   if(bg==0) bg=CLR_EDITBG;
   if(tc==0) tc=CLR_VALUE;
   if(ObjectFind(0,name)<0){ ObjectCreate(0,name,OBJ_EDIT,0,0,0); TrackObject(name); }
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,h);
   ObjectSetString (0,name,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,tc);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fs);
   ObjectSetString (0,name,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,name,OBJPROP_ALIGN,ALIGN_LEFT);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_READONLY,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,5);
}

//+------------------------------------------------------------------+
//| HELPERS                                                           |
//+------------------------------------------------------------------+
void SetTxt(string n,string t){ if(ObjectFind(0,n)>=0) ObjectSetString(0,n,OBJPROP_TEXT,t); }
void SetClr(string n,color c) { if(ObjectFind(0,n)>=0) ObjectSetInteger(0,n,OBJPROP_COLOR,c); }
void SetBG (string n,color c) { if(ObjectFind(0,n)>=0) ObjectSetInteger(0,n,OBJPROP_BGCOLOR,c); }
void SetVis(string n,bool vis){
   if(ObjectFind(0,n)>=0)
      ObjectSetInteger(0,n,OBJPROP_TIMEFRAMES,vis?OBJ_ALL_PERIODS:OBJ_NO_PERIODS);
}
void ResetBtn(string n){ if(ObjectFind(0,n)>=0) ObjectSetInteger(0,n,OBJPROP_STATE,false); }
string GetEdit(string n){ return (ObjectFind(0,n)>=0)?ObjectGetString(0,n,OBJPROP_TEXT):""; }
void   PutEdit(string n,string t){ if(ObjectFind(0,n)>=0) ObjectSetString(0,n,OBJPROP_TEXT,t); }
void SetBtnEnabled(string n,bool en,color enClr){
   if(ObjectFind(0,n)>=0){
      ObjectSetInteger(0,n,OBJPROP_BGCOLOR,en?enClr:C'36,36,36');
      ObjectSetInteger(0,n,OBJPROP_COLOR,  en?CLR_VALUE:CLR_LABEL);
   }
}
string FmtPrice(double v){ return DoubleToString(v,g_state.digits>0?g_state.digits:5); }
string FmtLot(double v)  { return DoubleToString(v,2); }
string FmtMoney(double v){ return "$"+DoubleToString(v,2); }

//+------------------------------------------------------------------+
//| LOT NORMALISATION (unchanged)                                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double step=g_state.volumeStep; if(step<=0) step=0.01;
   double n=MathFloor(lots/step)*step;
   n=MathMax(n,g_state.minLot);
   n=MathMin(n,g_state.maxLot);
   return NormalizeDouble(n,2);
}

//+------------------------------------------------------------------+
//| READ EDIT FIELDS                                                  |
//+------------------------------------------------------------------+
void ReadEditFields()
{
   string s;
   s=GetEdit(g_prefix+"ED_RISK");   if(s!=""&&StringToDouble(s)>0) g_state.tradeRisk=StringToDouble(s);
   s=GetEdit(g_prefix+"ED_LEV");    if(s!=""&&StringToDouble(s)>0) g_state.allowedLeverage=StringToDouble(s);
   s=GetEdit(g_prefix+"ED_MXMGN"); if(s!=""&&StringToDouble(s)>0) g_state.maxMarginAllowed=StringToDouble(s);
   s=GetEdit(g_prefix+"ED_MAXSPD");if(s!=""&&StringToInteger(s)>0) g_state.maxSpread=(int)StringToInteger(s);
   s=GetEdit(g_prefix+"ED_SPLIT");
   if(s!=""){ int sp=(int)StringToInteger(s); g_state.splitCount=(sp>=1&&sp<=3)?sp:1; }
   s=GetEdit(g_prefix+"ED_MAXPOS");if(s!=""&&StringToInteger(s)>0) g_state.maxPositions=(int)StringToInteger(s);
   s=GetEdit(g_prefix+"ED_SL");
   if(s!=""){
      double v=StringToDouble(s);
      if(g_state.slMode==SL_PRICE) g_state.slPrice=v;
      else if(v>0) g_state.slPips=(int)MathRound(v);
   }
   s=GetEdit(g_prefix+"ED_TP");
   if(s!=""){
      double v=StringToDouble(s);
      if(g_state.tpMode==TP_PRICE) g_state.tpPrice=v;
      else if(v>=0) g_state.tpPips=(int)MathRound(v);
   }
   s=GetEdit(g_prefix+"ED_PEND");
   if(s!="") g_state.pendingPrice=StringToDouble(s);
   // Read news fields — pass raw string; ParseNewsTime handles placeholder skip
   for(int i=0;i<3;i++){
      string ns=GetEdit(g_prefix+"ED_NEWS"+IntegerToString(i));
      StringTrimRight(ns); StringTrimLeft(ns);
      g_state.newsStr[i]=ns;
   }
}

//+------------------------------------------------------------------+
//| PIP SIZE — symbol-aware, no hardcoded values                    |
//+------------------------------------------------------------------+
double PipSize(){ return (g_state.digits<=3)?_Point:_Point*10.0; }
double PriceToPips(double p1,double p2){
   double ps=PipSize(); if(ps<=0) return 0;
   return MathAbs(p1-p2)/ps;
}

//+------------------------------------------------------------------+
//| LOT FROM DOLLAR RISK (unchanged)                                 |
//+------------------------------------------------------------------+
double CalcLotFromRisk(double riskDollars,double slPipsVal)
{
   if(slPipsVal<=0||g_state.tickValue<=0||g_state.tickSize<=0) return 0.0;
   double pipVal=(g_state.tickValue/g_state.tickSize)*PipSize();
   if(pipVal<=0) return 0.0;
   return riskDollars/(slPipsVal*pipVal);
}

//+------------------------------------------------------------------+
//| MAX LOT BY LEVERAGE (unchanged)                                  |
//+------------------------------------------------------------------+
double CalcMaxLotByLeverage()
{
   if(g_state.allowedLeverage<=0||g_state.ask<=0||g_state.contractSize<=0) return 0.0;
   return (g_state.accountBalance*g_state.allowedLeverage)/(g_state.ask*g_state.contractSize);
}

//+------------------------------------------------------------------+
//| MAX LOT BY MARGIN BUDGET (unchanged)                             |
//+------------------------------------------------------------------+
double CalcMaxLotByMargin()
{
   if(g_state.remainingMarginAvail<=0||g_state.ask<=0) return 0.0;
   double m1=0.0;
   OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,1.0,g_state.ask,m1);
   if(m1<=0) return 0.0;
   return g_state.remainingMarginAvail/m1;
}

//+------------------------------------------------------------------+
//| MARGIN FOR LOTS (unchanged)                                      |
//+------------------------------------------------------------------+
double CalcMargin(double lots)
{
   double m=0;
   OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lots,g_state.ask,m);
   return m;
}

//+------------------------------------------------------------------+
//| BROKER MINIMUM STOP DISTANCE (points)                           |
//+------------------------------------------------------------------+
double BrokerStopDist()
{
   return (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
}

//+------------------------------------------------------------------+
//| SL/TP CALCULATION — complete rewrite                            |
//|                                                                   |
//| isBuy is passed explicitly from orderType — no ambiguity.       |
//|                                                                   |
//| MT5 broker validation rules:                                     |
//|  BUY  order (fills at ASK):                                      |
//|    SL < ASK − StopLevel*Point   (SL is below ask)               |
//|    TP > ASK + StopLevel*Point   (TP is above ask)               |
//|  SELL order (fills at BID):                                      |
//|    SL > ASK + StopLevel*Point   (SL is above ask)               |
//|    TP < BID − StopLevel*Point   (TP is below bid)               |
//|                                                                   |
//| We build from entryPrice first, then apply broker clamp.        |
//+------------------------------------------------------------------+
void CalcSLTP(double entryPx, bool isBuy, double &outSL, double &outTP)
{
   int    dg      = g_state.digits;
   double pip     = PipSize();
   double ask     = g_state.ask;
   double bid     = g_state.bid;
   // safety margin = broker stop level + 1 extra pip
   double margin  = BrokerStopDist() + pip;

   // ──────────────────────────────────────────────────────────────
   // STOP LOSS
   // ──────────────────────────────────────────────────────────────
   if(g_state.slMode == SL_PRICE && g_state.slPrice > 0)
   {
      outSL = NormalizeDouble(g_state.slPrice, dg);
   }
   else
   {
      double dist = g_state.slPips * pip;
      if(dist < margin) dist = margin;
      outSL = isBuy
              ? NormalizeDouble(entryPx - dist, dg)   // BUY:  SL below entry
              : NormalizeDouble(entryPx + dist, dg);  // SELL: SL above entry
   }

   // Broker clamp — after pip calculation or user price entry
   if(isBuy)
   {
      // BUY SL must be strictly below ASK by at least margin
      double ceiling = NormalizeDouble(ask - margin, dg);
      if(outSL >= ask) outSL = ceiling;
   }
   else
   {
      // SELL SL must be strictly above ASK by at least margin
      double floor_sl = NormalizeDouble(ask + margin, dg);
      if(outSL <= ask) outSL = floor_sl;
   }

   // ──────────────────────────────────────────────────────────────
   // TAKE PROFIT
   // ──────────────────────────────────────────────────────────────
   if(g_state.tpMode == TP_PRICE && g_state.tpPrice > 0)
   {
      outTP = NormalizeDouble(g_state.tpPrice, dg);
   }
   else if(g_state.tpPips > 0)
   {
      double dist = g_state.tpPips * pip;
      if(dist < margin) dist = margin;
      outTP = isBuy
              ? NormalizeDouble(entryPx + dist, dg)   // BUY:  TP above entry
              : NormalizeDouble(entryPx - dist, dg);  // SELL: TP below entry
   }
   else { outTP = 0.0; }

   if(outTP > 0.0)
   {
      if(isBuy)
      {
         // BUY TP must be strictly above ASK by at least margin
         double floor_tp = NormalizeDouble(ask + margin, dg);
         if(outTP <= ask) outTP = floor_tp;
      }
      else
      {
         // SELL TP must be strictly below BID by at least margin
         double ceiling_tp = NormalizeDouble(bid - margin, dg);
         if(outTP >= bid) outTP = ceiling_tp;
      }
   }

   // Diagnostic log — visible in MT5 Experts tab
   PrintFormat(
      "CalcSLTP [%s] entry=%.5f ask=%.5f bid=%.5f "
      "SL=%.5f(must be %s %.5f)  TP=%.5f(must be %s %.5f)  margin=%.5f",
      isBuy?"BUY":"SELL",
      entryPx, ask, bid,
      outSL, isBuy?"<":">",(isBuy?ask-margin:ask+margin),
      outTP, isBuy?">":"<",(isBuy?ask+margin:bid-margin),
      margin);
}

//+------------------------------------------------------------------+
//| PRE-EXECUTION SANITY CHECK                                       |
//| Returns true if SL/TP are on the correct side.                  |
//| Logs and blocks execution if not.                               |
//+------------------------------------------------------------------+
bool SanityCheckStops(bool isBuy, double entryPx, double sl, double tp,
                      string &errMsg)
{
   double ask = g_state.ask;
   double bid = g_state.bid;
   double margin = BrokerStopDist() + PipSize();

   if(isBuy)
   {
      if(sl >= ask){
         errMsg=StringFormat("BUY SL WRONG SIDE: SL=%.5f must be < ASK=%.5f",sl,ask);
         return false;
      }
      if(tp > 0 && tp <= ask){
         errMsg=StringFormat("BUY TP WRONG SIDE: TP=%.5f must be > ASK=%.5f",tp,ask);
         return false;
      }
      if(ask - sl < margin){
         errMsg=StringFormat("BUY SL TOO CLOSE: gap=%.5f < required=%.5f",ask-sl,margin);
         return false;
      }
   }
   else
   {
      if(sl <= ask){
         errMsg=StringFormat("SELL SL WRONG SIDE: SL=%.5f must be > ASK=%.5f",sl,ask);
         return false;
      }
      if(tp > 0 && tp >= bid){
         errMsg=StringFormat("SELL TP WRONG SIDE: TP=%.5f must be < BID=%.5f",tp,bid);
         return false;
      }
      if(sl - ask < margin){
         errMsg=StringFormat("SELL SL TOO CLOSE: gap=%.5f < required=%.5f",sl-ask,margin);
         return false;
      }
   }
   errMsg="";
   return true;
}

//+------------------------------------------------------------------+
//| COUNT positions + orders                                         |
//+------------------------------------------------------------------+
int CountAllPositions(){ return PositionsTotal()+OrdersTotal(); }

//+------------------------------------------------------------------+
//| SUM open position margin on this symbol                         |
//+------------------------------------------------------------------+
double SumOpenPositionMargin()
{
   double total=0;
   for(int i=0;i<PositionsTotal();i++){
      if(!g_position.SelectByIndex(i)||g_position.Symbol()!=_Symbol) continue;
      double m=0;
      ENUM_ORDER_TYPE ot=(g_position.PositionType()==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      OrderCalcMargin(ot,_Symbol,g_position.Volume(),g_position.PriceOpen(),m);
      total+=m;
   }
   return total;
}

//+------------------------------------------------------------------+
//| NEWS PARSING                                                      |
//+------------------------------------------------------------------+

// Returns the current server time converted to IST as a formatted string.
// Format: DD-MM-YYYY HH:MM
string CurrentISTString()
{
   datetime istNow = TimeLocal();
   MqlDateTime d; TimeToStruct(istNow, d);
   return StringFormat("%02d-%02d-%04d %02d:%02d",
                       d.day, d.mon, d.year, d.hour, d.min);
}

// Parse "DD-MM-YYYY HH:MM" (IST) → UTC datetime.
// Returns 0 if blank, showing placeholder, or unparseable.
// Accepts HH=24 and treats it as 00:00 of the next day.
datetime ParseNewsTime(string s)
{
   StringTrimRight(s); StringTrimLeft(s);
   if(s==""||s=="0"||s=="DD-MM-YYYY HH:MM") return 0;

   // Must contain a space between date and time
   string parts[];
   if(StringSplit(s,' ',parts)<2){
      PrintFormat("NewsFilter: bad format (no space) in '%s'",s); return 0;
   }
   string datePart=parts[0], timePart=parts[1];

   // Date: DD-MM-YYYY
   string dp[];
   if(StringSplit(datePart,'-',dp)<3){
      PrintFormat("NewsFilter: bad date part '%s'",datePart); return 0;
   }
   int day  = (int)StringToInteger(dp[0]);
   int mon  = (int)StringToInteger(dp[1]);
   int year = (int)StringToInteger(dp[2]);
   if(mon<1||mon>12||day<1||day>31||year<2000){
      PrintFormat("NewsFilter: date out of range D=%d M=%d Y=%d",day,mon,year); return 0;
   }

   // Time: HH:MM  — strip any trailing non-digit chars (spaces, AM/PM remnants)
   string tp=timePart;
   StringTrimRight(tp); StringTrimLeft(tp);
   string tp2[];
   if(StringSplit(tp,':',tp2)<2){
      PrintFormat("NewsFilter: bad time part '%s'",tp); return 0;
   }
   int hh=(int)StringToInteger(tp2[0]);
   int mm=(int)StringToInteger(tp2[1]);

   // Accept HH=24 as midnight of the following day
   bool nextDay=false;
   if(hh==24){ hh=0; mm=0; nextDay=true; }
   if(hh<0||hh>23||mm<0||mm>59){
      PrintFormat("NewsFilter: time out of range HH=%d MM=%d in '%s'",hh,mm,s); return 0;
   }

   MqlDateTime md;
   md.year=year; md.mon=mon; md.day=day;
   md.hour=hh;   md.min=mm;  md.sec=0;
   datetime t = StructToTime(md);
   if(nextDay) t += 86400;   // add one day

   // Store as IST datetime directly.
   // We compare against server time converted to IST, so no UTC conversion needed.
   PrintFormat("NewsFilter: parsed '%s' → IST datetime %s",s,TimeToString(t));
   return t;
}

// Format seconds into "Xm Ys" string
string FmtCountdown(int totalSec)
{
   if(totalSec<0) totalSec=0;
   int m=totalSec/60, s=totalSec%60;
   return StringFormat("%dm %02ds",m,s);
}

// Format stored IST datetime as HH:MM IST string (value is already in IST)
string FmtISTTime(datetime ist)
{
   MqlDateTime d; TimeToStruct(ist,d);
   return StringFormat("%02d:%02d IST",d.hour,d.min);
}

// Full IST date+time string (value is already in IST)
string FmtISTDateTime(datetime ist)
{
   MqlDateTime d; TimeToStruct(ist,d);
   string mons[]={"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
   return StringFormat("%02d-%s-%04d %02d:%02d",d.day,mons[d.mon-1],d.year,d.hour,d.min);
}

bool CheckNewsBlocking(string &outMsg)
{
   // Convert server time to IST for comparison (newsTime values are stored in IST)
   datetime now = TimeLocal();
   datetime blk = (datetime)(NEWS_BLOCK_MINS*60);
   datetime upcoming_window = (datetime)(60*60); // warn 60 min ahead

   // Reset countdown/upcoming fields
   g_state.newsNextLabel = "";
   g_state.newsCountdown = "";
   g_state.newsUpcoming  = false;

   // ── STEP 1: Check if currently inside any block window ───────────
   for(int i=0;i<3;i++){
      if(g_state.newsTime[i]==0) continue;
      datetime wStart = g_state.newsTime[i] - blk;
      datetime wEnd   = g_state.newsTime[i] + blk;
      if(now >= wStart && now <= wEnd){
         string istTime = FmtISTTime(g_state.newsTime[i]);
         outMsg = StringFormat("⚠ NEWS TIME — NO TRADE  [Event %d  %s  ±%d min]",
                               i+1, istTime, NEWS_BLOCK_MINS);
         int secsLeft = (int)(wEnd - now);
         g_state.newsNextLabel = StringFormat("News Event %d: %s", i+1, istTime);
         g_state.newsCountdown = "Trading Resumes In: " + FmtCountdown(secsLeft);
         g_state.newsUpcoming  = false;
         return true;
      }
   }

   // ── STEP 2: Find nearest FUTURE event (block window not yet started) ─
   datetime nearest    = 0;
   int      nearestIdx = -1;
   for(int i=0;i<3;i++){
      if(g_state.newsTime[i]==0) continue;
      datetime wStart = g_state.newsTime[i] - blk;
      if(wStart > now){   // block hasn't started yet
         if(nearest==0 || wStart < nearest){ nearest=wStart; nearestIdx=i; }
      }
   }

   if(nearestIdx >= 0){
      int secsToBlock = (int)(nearest - now);
      string istTime  = FmtISTTime(g_state.newsTime[nearestIdx]);
      g_state.newsNextLabel = StringFormat("Next News: %s (Event %d)",
                                           istTime, nearestIdx+1);
      if(secsToBlock <= (int)upcoming_window){
         g_state.newsCountdown = "Block Starts In: " + FmtCountdown(secsToBlock);
         g_state.newsUpcoming  = true;
      } else {
         g_state.newsCountdown = StringFormat("Block Starts In: %s",FmtCountdown(secsToBlock));
         g_state.newsUpcoming  = false;
      }
   }

   outMsg = "";
   return false;
}

//+------------------------------------------------------------------+
//| UPDATE STATE                                                      |
//+------------------------------------------------------------------+
void UpdateState()
{
   ReadEditFields();

   // Account
   g_state.accountBalance  =AccountInfoDouble(ACCOUNT_BALANCE);
   g_state.accountEquity   =AccountInfoDouble(ACCOUNT_EQUITY);
   g_state.freeMargin      =AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   g_state.usedMargin      =AccountInfoDouble(ACCOUNT_MARGIN);
   g_state.accountLeverage =(int)AccountInfoInteger(ACCOUNT_LEVERAGE);

   // Symbol specs — all from broker
   g_state.ask          =SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   g_state.bid          =SymbolInfoDouble(_Symbol,SYMBOL_BID);
   g_state.currentSpread=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   g_state.contractSize =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   g_state.tickSize     =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   g_state.tickValue    =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   g_state.digits       =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_state.volumeStep   =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_state.minLot       =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_state.maxLot       =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

   g_state.spreadOk=(g_state.currentSpread<=g_state.maxSpread);

   // Direction: read directly from orderType
   bool isBuy = OrderIsBuy(g_state.orderType);

   // Entry price
   bool isPending = (g_state.orderType==OTYPE_BUY_LIMIT  ||
                     g_state.orderType==OTYPE_SELL_LIMIT  ||
                     g_state.orderType==OTYPE_BUY_STOP    ||
                     g_state.orderType==OTYPE_SELL_STOP);
   if(!isPending)
      g_state.entryPrice = isBuy ? g_state.ask : g_state.bid;
   else
      g_state.entryPrice = (g_state.pendingPrice>0)
                          ? g_state.pendingPrice
                          : (isBuy ? g_state.ask : g_state.bid);

   // SL/TP — uses explicit isBuy flag (no ambiguity)
   CalcSLTP(g_state.entryPrice, isBuy, g_state.computedSL, g_state.computedTP);

   // Lot
   double slPipsFC=0.0;
   if(g_state.slMode==SL_PRICE&&g_state.slPrice>0)
      slPipsFC=PriceToPips(g_state.entryPrice,g_state.slPrice);
   else
      slPipsFC=(double)g_state.slPips;
   g_state.calculatedLotSize=(slPipsFC>0)?NormalizeLot(CalcLotFromRisk(g_state.tradeRisk,slPipsFC)):0.0;

   // Margin analysis
   g_state.marginAlreadyUsed   =SumOpenPositionMargin();
   g_state.remainingMarginAvail=MathMax(0,g_state.maxMarginAllowed-g_state.marginAlreadyUsed);
   g_state.maxLotByLeverage    =NormalizeLot(CalcMaxLotByLeverage());
   g_state.maxLotByMargin      =NormalizeLot(CalcMaxLotByMargin());
   g_state.maxAllowedLot       =MathMin(g_state.maxLotByLeverage,g_state.maxLotByMargin);
   if(g_state.maxAllowedLot<=0&&g_state.maxLotByLeverage>0)
      g_state.maxAllowedLot=g_state.maxLotByLeverage;
   g_state.marginRequired=CalcMargin(g_state.calculatedLotSize);

   // R:R
   double tpPipsFC=(g_state.tpMode==TP_PRICE&&g_state.tpPrice>0)
                  ?PriceToPips(g_state.entryPrice,g_state.tpPrice):(double)g_state.tpPips;
   g_state.riskRewardRatio=(slPipsFC>0&&tpPipsFC>0)?tpPipsFC/slPipsFC:0.0;

   // Checks
   g_state.leverageOk=(g_state.calculatedLotSize>0&&
                        g_state.calculatedLotSize<=g_state.maxAllowedLot);
   g_state.positionLimitOk=(CountAllPositions()+g_state.splitCount<=g_state.maxPositions);

   // News
   for(int i=0;i<3;i++) g_state.newsTime[i]=ParseNewsTime(g_state.newsStr[i]);
   g_state.newsBlocking=CheckNewsBlocking(g_state.newsBlockMsg);

   // Validation
   g_state.isValid=true; g_state.validationMessage="";
   if(g_state.calculatedLotSize<=0)
   { g_state.isValid=false; g_state.validationMessage="Lot=0. Check SL setting."; }
   else if(!g_state.leverageOk)
   { g_state.isValid=false; g_state.validationMessage="Lot exceeds max (leverage/margin cap)."; }
   else if(!g_state.spreadOk)
   { g_state.isValid=false; g_state.validationMessage="Spread too high!"; }
   else if(g_state.marginRequired>g_state.freeMargin)
   { g_state.isValid=false; g_state.validationMessage="Insufficient free margin."; }
   else if(!g_state.positionLimitOk)
   { g_state.isValid=false; g_state.validationMessage="Max position limit reached (max="+IntegerToString(g_state.maxPositions)+")."; }
   else if(g_state.newsBlocking)
   { g_state.isValid=false; g_state.validationMessage="NEWS FILTER ACTIVE — Trading disabled."; }
}

//+------------------------------------------------------------------+
//| DEFAULT SL FOR PENDING ORDERS                                    |
//+------------------------------------------------------------------+
void AutoFillPendingSL()
{
   bool isPend=(g_state.orderType!=OTYPE_MARKET_BUY&&g_state.orderType!=OTYPE_MARKET_SELL);
   if(!isPend) return;
   double pe=g_state.pendingPrice; if(pe<=0) return;
   bool isBuy=OrderIsBuy(g_state.orderType);
   double dist=1000.0*PipSize();
   double dSL=isBuy?NormalizeDouble(pe-dist,g_state.digits)
                   :NormalizeDouble(pe+dist,g_state.digits);
   if(g_state.slMode==SL_PRICE){ g_state.slPrice=dSL; PutEdit(g_prefix+"ED_SL",FmtPrice(dSL)); }
   else { g_state.slPips=1000; PutEdit(g_prefix+"ED_SL","1000"); }
}

//+------------------------------------------------------------------+
//| BUILD DASHBOARD                                                   |
//+------------------------------------------------------------------+
void BuildDashboard()
{
   int X=PNL_X,Y=PNL_Y;
   int GAP=S(5);
   int lx=X+S(4), curY=Y+S(24);

   CreateRect(g_prefix+"BG",X,Y,PNL_W(),S(800),CLR_BG,CLR_BORDER,1);

   // ── TITLE BAR ─────────────────────────────────────────────────────
   CreateRect(g_prefix+"TITLEBAR",X,Y,PNL_W(),S(20),CLR_HDR,CLR_BORDER,1);
   CreateLabel(g_prefix+"TITLE",X+S(6),Y+S(4),
      "MT5 MANUAL TRADING DASHBOARD  |  "+_Symbol,CLR_WARN,FS(8),"Arial Bold");
   CreateLabel(g_prefix+"SRVTIME",X+PNL_W()-S(248),Y+S(5),"SRV:--:--:--",CLR_INFO,FS(7));
   CreateLabel(g_prefix+"LOCTIME",X+PNL_W()-S(152),Y+S(5),"LOC:--:--:--",CLR_INFO,FS(7));
   CreateButton(g_prefix+"BTN_ZM",X+PNL_W()-S(84),Y+S(2),S(40),S(16),"Zoom-",CLR_BTN,CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_ZP",X+PNL_W()-S(42),Y+S(2),S(40),S(16),"Zoom+",CLR_BTN,CLR_VALUE,FS(7));

   // ─── A1: ACCOUNT INFO ─────────────────────────────────────────────
   int A1H=S(42);
   CreateRect(g_prefix+"ACC_BG",lx,curY,COL_AW()-S(4),A1H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"ACC_HDR",lx+S(5),curY+S(2),"ACCOUNT",CLR_WARN,FS(7),"Arial Bold");
   int ax[]={lx+S(5),lx+S(93),lx+S(188),lx+S(282),lx+S(370)};
   string alk[]={"BAL","EQ","LEV","UMGN","SPR"};
   string alt[]={"Balance","Equity","Leverage","Used Margin","Spread"};
   for(int i=0;i<5;i++){
      CreateLabel(g_prefix+"AL_"+alk[i],ax[i],curY+S(14),alt[i],CLR_LABEL,FS(7));
      CreateLabel(g_prefix+"AV_"+alk[i],ax[i],curY+S(27),"---",CLR_VALUE,FS(8),"Arial Bold");
   }
   curY+=A1H+GAP;

   // ─── A2: RISK SETTINGS ───────────────────────────────────────────
   int A2H=S(44), rCW=(COL_AW()-S(14))/6;
   CreateRect(g_prefix+"RSK_BG",lx,curY,COL_AW()-S(4),A2H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"RSK_HDR",lx+S(5),curY+S(2),"RISK SETTINGS",CLR_WARN,FS(7),"Arial Bold");
   string rlk[]={"RISK","LEV","MXMGN","MAXSPD","SPLIT","MAXPOS"};
   string rlt[]={"Risk ($)","Allow.Lev","Max Margin","Max Sprd","Split","Max Pos"};
   string rld[]={DoubleToString(InpTradeRisk,0),DoubleToString(InpAllowedLeverage,0),
                 DoubleToString(InpMaxMargin,0),IntegerToString(InpMaxSpread),
                 IntegerToString(InpSplitTrades),IntegerToString(InpMaxPositions)};
   for(int i=0;i<6;i++){
      int fx=lx+S(4)+i*rCW;
      CreateLabel(g_prefix+"RL_"+rlk[i],fx,curY+S(14),rlt[i],CLR_LABEL,FS(6));
      CreateEdit (g_prefix+"ED_"+rlk[i],fx,curY+S(26),rCW-S(5),EDIT_H(),rld[i]);
   }
   curY+=A2H+GAP;

   // ─── A3: SL / TP / PENDING ENTRY ─────────────────────────────────
   int A3H=S(78);
   CreateRect(g_prefix+"SLTP_BG",lx,curY,COL_AW()-S(4),A3H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"SLTP_HDR",lx+S(5),curY+S(2),"SL / TP / ENTRY PRICE",CLR_WARN,FS(7),"Arial Bold");
   int slEW=S(80),slBW=S(54);
   int slCX=lx+S(5)+slEW+slBW+S(10);
   CreateLabel(g_prefix+"SL_LBL",   lx+S(5),            curY+S(14),"Stop Loss",  CLR_LABEL,FS(7));
   CreateEdit (g_prefix+"ED_SL",    lx+S(5),            curY+S(27),slEW,EDIT_H(),IntegerToString(InpSLPips));
   CreateButton(g_prefix+"BTN_SLMD",lx+S(5)+slEW+S(3), curY+S(27),slBW,EDIT_H(),"PIPS",CLR_BTN,CLR_VALUE,FS(7));
   CreateLabel(g_prefix+"SL_CALC",  slCX,               curY+S(32),"SL: ---",    CLR_SELL,FS(7));
   CreateLabel(g_prefix+"TP_LBL",   lx+S(5),            curY+S(46),"Take Profit",CLR_LABEL,FS(7));
   CreateEdit (g_prefix+"ED_TP",    lx+S(5),            curY+S(58),slEW,EDIT_H(),IntegerToString(InpTPPips));
   CreateButton(g_prefix+"BTN_TPMD",lx+S(5)+slEW+S(3), curY+S(58),slBW,EDIT_H(),"PIPS",CLR_BTN,CLR_VALUE,FS(7));
   CreateLabel(g_prefix+"TP_CALC",  slCX,               curY+S(63),"TP: ---  RR:---",CLR_BUY,FS(7));
   int pX=lx+S(262);
   CreateLabel(g_prefix+"PEND_LBL", pX,curY+S(14),"Entry Price (Pending)",CLR_LABEL,FS(7));
   CreateEdit (g_prefix+"ED_PEND",  pX,curY+S(27),S(130),EDIT_H(),"0.00000");
   CreateLabel(g_prefix+"PEND_NOTE",pX,curY+S(50),"0 = use market price", CLR_LABEL,FS(7));
   curY+=A3H+GAP;

   // ─── A4: ORDER TYPE + LOT + EXECUTION ─────────────────────────────
   // Dropdown now has 6 items (Market Buy / Market Sell / 4 pending)
   // BUY button only lights up for buy-direction types.
   // SELL button only lights up for sell-direction types.
   int A4H=S(68);
   CreateRect(g_prefix+"ORD_BG",lx,curY,COL_AW()-S(4),A4H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"ORD_HDR",lx+S(5),curY+S(2),"ORDER TYPE & EXECUTION",CLR_WARN,FS(7),"Arial Bold");
   CreateButton(g_prefix+"BTN_DD",lx+S(5),curY+S(17),S(150),S(22),"Market Buy  ▼",CLR_DDOPEN,CLR_VALUE,FS(8));
   // 6 dropdown items
   for(int i=0;i<6;i++){
      color ddClr=(i==0||i==2||i==4)?C'0,55,0':C'55,0,0';
      CreateButton(g_prefix+"DD_"+IntegerToString(i),
                   lx+S(5),curY+S(41)+i*S(19),S(150),S(18),
                   g_ddLabels[i],ddClr,CLR_VALUE,FS(7));
      SetVis(g_prefix+"DD_"+IntegerToString(i),false);
   }
   // Lot block
   CreateLabel(g_prefix+"LOT_LBL",  lx+S(165),curY+S(14),"Lot Size:",  CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"LOT_VAL",  lx+S(165),curY+S(28),"0.00 lots",  CLR_VALUE,FS(11),"Arial Bold");
   CreateLabel(g_prefix+"LOT_NOTE", lx+S(165),curY+S(45),"live",        CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"LOT_MXLOT",lx+S(165),curY+S(56),"Max: 0.00",  CLR_LABEL,FS(7));
   // BUY / SELL buttons
   int bW=S(104),bH=S(34);
   CreateButton(g_prefix+"BTN_BUY", lx+S(262),curY+S(14),bW,bH,"BUY  (B)", CLR_BUY, CLR_VALUE,FS(11));
   CreateButton(g_prefix+"BTN_SELL",lx+S(372),curY+S(14),bW,bH,"SELL (S)", CLR_SELL,CLR_VALUE,FS(11));
   CreateLabel(g_prefix+"VAL_STATUS",lx+S(262),curY+S(53),"CHECKING...",CLR_WARN,FS(7),"Arial Bold");
   curY+=A4H+GAP;

   // ─── A5: PRE-EXECUTION VERIFICATION ──────────────────────────────
   // Live display of Entry/SL/TP for both Buy and Sell direction.
   int A5H=S(56);
   CreateRect(g_prefix+"PREV_BG",lx,curY,COL_AW()-S(4),A5H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"PREV_HDR",lx+S(5),curY+S(2),"PRE-EXECUTION VERIFICATION",CLR_WARN,FS(7),"Arial Bold");
   // Direction label
   CreateLabel(g_prefix+"PREV_DIR",lx+S(5),curY+S(16),"Direction: ---",CLR_VALUE,FS(8),"Arial Bold");
   // Three values in a row: Entry | SL | TP
   int pvx[]={lx+S(5),lx+S(145),lx+S(285)};
   CreateLabel(g_prefix+"PREV_EL",pvx[0],curY+S(30),"Entry:",    CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"PREV_EV",pvx[0],curY+S(42),"---",       CLR_VALUE,FS(8),"Arial Bold");
   CreateLabel(g_prefix+"PREV_SL",pvx[1],curY+S(30),"Stop Loss:",CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"PREV_SV",pvx[1],curY+S(42),"---",       CLR_SELL, FS(8),"Arial Bold");
   CreateLabel(g_prefix+"PREV_TL",pvx[2],curY+S(30),"Take Profit:",CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"PREV_TV",pvx[2],curY+S(42),"---",        CLR_BUY,  FS(8),"Arial Bold");
   // SL/TP sanity indicator
   CreateLabel(g_prefix+"PREV_OK",lx+COL_AW()-S(120),curY+S(16),"",CLR_VALID,FS(7),"Arial Bold");
   curY+=A5H+GAP;

   // ─── A6: MAX LOT & MARGIN ANALYSIS ───────────────────────────────
   int A6H=S(72);
   CreateRect(g_prefix+"MXLOT_BG",lx,curY,COL_AW()-S(4),A6H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"MXLOT_HDR",lx+S(5),curY+S(2),"MAX LOT & MARGIN ANALYSIS",CLR_WARN,FS(7),"Arial Bold");
   int m1x=lx+S(5),m2x=lx+S(150),m3x=lx+S(242),m4x=lx+S(375);
   CreateLabel(g_prefix+"ML_LL",m1x,curY+S(16),"Max Lot (Leverage):", CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"ML_LV",m2x,curY+S(16),"---",                 CLR_VALUE,FS(7),"Arial Bold");
   CreateLabel(g_prefix+"ML_ML",m1x,curY+S(30),"Max Lot (Margin):",   CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"ML_MV",m2x,curY+S(30),"---",                 CLR_VALUE,FS(7),"Arial Bold");
   CreateLabel(g_prefix+"ML_FL",m1x,curY+S(44),"Final Max Lot:",      CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"ML_FV",m2x,curY+S(44),"---",                 CLR_VALID,FS(8),"Arial Bold");
   CreateLabel(g_prefix+"MB_AL",m3x,curY+S(16),"Margin Allowed:",     CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"MB_AV",m4x,curY+S(16),"---",                 CLR_VALUE,FS(7));
   CreateLabel(g_prefix+"MB_UL",m3x,curY+S(30),"Margin Used:",        CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"MB_UV",m4x,curY+S(30),"---",                 CLR_WARN2,FS(7));
   CreateLabel(g_prefix+"MB_RL",m3x,curY+S(44),"Remaining Avail:",    CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"MB_RV",m4x,curY+S(44),"---",                 CLR_VALID,FS(7),"Arial Bold");
   CreateLabel(g_prefix+"ML_WARN",m1x,curY+S(59),"",                  CLR_INVALID,FS(7),"Arial Bold");
   curY+=A6H+GAP;

   // ─── A7: QUICK MANAGEMENT ─────────────────────────────────────────
   int A7H=S(42);
   CreateRect(g_prefix+"QC_BG",lx,curY,COL_AW()-S(4),A7H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"QC_HDR",lx+S(5),curY+S(2),"QUICK MANAGEMENT",CLR_WARN,FS(7),"Arial Bold");
   int qbw2=(COL_AW()-S(22))/6, qgp=S(3);
   CreateButton(g_prefix+"BTN_CSEL", lx+S(5)+0*(qbw2+qgp),curY+S(16),qbw2,BTN_H(),"Close Sel.",  CLR_BTN,   CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_CALL", lx+S(5)+1*(qbw2+qgp),curY+S(16),qbw2,BTN_H(),"Close All",   CLR_BTN,   CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_CPROF",lx+S(5)+2*(qbw2+qgp),curY+S(16),qbw2,BTN_H(),"Close Profit",C'0,68,0', CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_CLOSS",lx+S(5)+3*(qbw2+qgp),curY+S(16),qbw2,BTN_H(),"Close Loss",  C'68,0,0', CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_BESEL",lx+S(5)+4*(qbw2+qgp),curY+S(16),qbw2,BTN_H(),"BE Selected", CLR_BTN,   CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_BEALL",lx+S(5)+5*(qbw2+qgp),curY+S(16),qbw2,BTN_H(),"BE All",      CLR_BTN,   CLR_VALUE,FS(7));
   curY+=A7H+GAP;

   // ─── A8: NEWS FILTER ──────────────────────────────────────────────
   // Compact layout: header + one row of 3 labelled edit boxes + status/countdown
   // Each edit box shows placeholder "DD-MM-YYYY HH:MM" as initial text.
   // User clicks the field, clears it, and types in the required date/time.
   int A8H=S(90);
   CreateRect(g_prefix+"NEWS_BG",lx,curY,COL_AW()-S(4),A8H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"NEWS_HDR",lx+S(5),curY+S(2),
      "NEWS FILTER  (IST UTC+05:30)  |  Block: ±"+IntegerToString(NEWS_BLOCK_MINS)+
      " min  |  Format: DD-MM-YYYY HH:MM",CLR_WARN,FS(7),"Arial Bold");

   int newsEW=S(182), newsGP=S(6);
   for(int i=0;i<3;i++){
      int nx=lx+S(5)+i*(newsEW+newsGP);
      CreateLabel(g_prefix+"NEWS_L"+IntegerToString(i),   nx, curY+S(14),
         "News "+(string)(i+1)+":", CLR_LABEL,FS(7));
      // Placeholder text shows required format — user clicks, clears, and types
      CreateEdit (g_prefix+"ED_NEWS"+IntegerToString(i),  nx, curY+S(25),
         newsEW, EDIT_H(), "DD-MM-YYYY HH:MM");
      // Per-field parse status (✔ / ✖)
      CreateLabel(g_prefix+"NEWS_PS"+IntegerToString(i),  nx, curY+S(46),
         "", CLR_LABEL,FS(6));
   }
   // Status + countdown on two compact lines
   CreateLabel(g_prefix+"NEWS_STAT", lx+S(5), curY+S(57),"",CLR_NEWS,FS(7),"Arial Bold");
   CreateLabel(g_prefix+"NEWS_NEXT", lx+S(5), curY+S(66),"",CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"NEWS_CNTD", lx+S(5), curY+S(75),"",CLR_WARN, FS(7),"Arial Bold");
   curY+=A8H+GAP;

   // ─── A9: EMERGENCY + NEWS WARNING ────────────────────────────────
   CreateButton(g_prefix+"BTN_KILL",lx,curY,COL_AW()-S(4),S(24),
      "⚠  EMERGENCY KILL SWITCH  — Close All + Cancel All  (C)",
      CLR_KILL,CLR_VALUE,FS(8));
   curY+=S(24)+GAP;
   // News warning block: big red message when blocking
   CreateLabel(g_prefix+"NEWS_WARN",  lx,curY," ",CLR_NEWS,FS(10),"Arial Bold");
   curY+=S(18)+GAP;
   CreateLabel(g_prefix+"NEWS_WARN2", lx,curY," ",CLR_WARN,FS(8),"Arial Bold");
   curY+=S(16)+GAP;

   // Resize panel height
   ObjectSetInteger(0,g_prefix+"BG",OBJPROP_YSIZE,curY-Y+S(4));

   // ── RIGHT COLUMN ──────────────────────────────────────────────────
   int rx=X+COL_BX();

   // ─── B1: POSITIONS TABLE ──────────────────────────────────────────
   int TBL_Y=Y+S(24), TBL_H=S(232);
   CreateRect(g_prefix+"TBL_BG",rx,TBL_Y,COL_BW()-S(2),TBL_H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"TBL_HDR",rx+S(5),TBL_Y+S(2),"OPEN POSITIONS & ORDERS",CLR_WARN,FS(7),"Arial Bold");
   int tc[]={rx+S(2),rx+S(50),rx+S(100),rx+S(145),rx+S(192),rx+S(248),rx+S(300),rx+S(356),rx+S(412)};
   string th[]={"Ticket","Sym","Type","Lots","Entry","Current","SL","TP","P/L"};
   int th_y=TBL_Y+S(15);
   for(int i=0;i<9;i++)
      CreateLabel(g_prefix+"TH_"+IntegerToString(i),tc[i],th_y,th[i],CLR_WARN,FS(7),"Arial Bold");
   for(int r=0;r<12;r++){
      int ry=th_y+S(14)+r*ROW_H();
      for(int c=0;c<9;c++)
         CreateLabel(g_prefix+"TR_"+IntegerToString(r)+"_"+IntegerToString(c),tc[c],ry,"",CLR_VALUE,FS(7));
      CreateButton(g_prefix+"TR_SEL_"+IntegerToString(r),
                   rx+COL_BW()-S(30),ry-S(2),S(28),ROW_H(),"SEL",CLR_BTN,CLR_LABEL,FS(6));
   }
   int TBL_END=TBL_Y+TBL_H;

   // ─── B2: TRADE MODIFICATION ───────────────────────────────────────
   int MY=TBL_END+GAP, MOD_H=S(70);
   CreateRect(g_prefix+"MOD_BG",rx,MY,COL_BW()-S(2),MOD_H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"MOD_HDR",rx+S(5),MY+S(2),"TRADE MODIFICATION",CLR_WARN,FS(7),"Arial Bold");
   CreateLabel(g_prefix+"MOD_SEL",rx+S(5),MY+S(15),"No trade selected — click SEL to select",CLR_INFO,FS(7));
   int nW=S(116);
   CreateLabel(g_prefix+"MOD_SLL",rx+S(5),           MY+S(29),"New SL (blank=keep):",CLR_LABEL,FS(7));
   CreateEdit (g_prefix+"ED_NSL", rx+S(5),           MY+S(41),nW,EDIT_H(),"");
   CreateLabel(g_prefix+"MOD_TPL",rx+S(5)+nW+S(10),  MY+S(29),"New TP (blank=keep):",CLR_LABEL,FS(7));
   CreateEdit (g_prefix+"ED_NTP", rx+S(5)+nW+S(10),  MY+S(41),nW,EDIT_H(),"");
   CreateButton(g_prefix+"BTN_MOD",rx+S(5)+nW*2+S(22),MY+S(37),S(78),BTN_H()+S(4),"MODIFY",C'36,76,36',CLR_VALUE,FS(9));
   int cpX=rx+S(5)+nW*2+S(108);
   CreateButton(g_prefix+"BTN_CPOS",cpX,MY+S(21),S(140),BTN_H(),"Cancel Sel. Pending",CLR_BTN,CLR_VALUE,FS(7));
   CreateButton(g_prefix+"BTN_CAPO",cpX,MY+S(46),S(140),BTN_H(),"Cancel All Pending",  CLR_BTN,CLR_VALUE,FS(7));
   int BY=MY+MOD_H+GAP;

   // ─── B3: PRE-TRADE VALIDATION SUMMARY ────────────────────────────
   int VAL_H=S(80);
   CreateRect(g_prefix+"VSUM_BG",rx,BY,COL_BW()-S(2),VAL_H,CLR_SECT,CLR_BORDER,1);
   CreateLabel(g_prefix+"VSUM_HDR",rx+S(5),BY+S(2),"PRE-TRADE VALIDATION",CLR_WARN,FS(7),"Arial Bold");
   int sv1=rx+S(5),sv2=rx+S(262);
   CreateLabel(g_prefix+"VS_RL", sv1,      BY+S(16),"Risk:",         CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_RV", sv1+S(65),BY+S(16),"$0.00",         CLR_VALUE,FS(7),"Arial Bold");
   CreateLabel(g_prefix+"VS_LL", sv1,      BY+S(30),"Lot Size:",      CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_LV", sv1+S(65),BY+S(30),"0.00",           CLR_VALUE,FS(8),"Arial Bold");
   CreateLabel(g_prefix+"VS_ML", sv1,      BY+S(44),"Margin Req:",    CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_MV", sv1+S(65),BY+S(44),"$0.00",          CLR_VALUE,FS(7));
   CreateLabel(g_prefix+"VS_XL", sv1,      BY+S(58),"Final Max Lot:", CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_XV", sv1+S(65),BY+S(58),"0.00",            CLR_VALUE,FS(7));
   CreateLabel(g_prefix+"VS_RRL",sv2,      BY+S(16),"R:R Ratio:",     CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_RRV",sv2+S(68),BY+S(16),"---",             CLR_VALUE,FS(7));
   CreateLabel(g_prefix+"VS_SLL",sv2,      BY+S(30),"SL Price:",       CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_SLV",sv2+S(68),BY+S(30),"---",             CLR_SELL, FS(7),"Arial Bold");
   CreateLabel(g_prefix+"VS_TPL",sv2,      BY+S(44),"TP Price:",       CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_TPV",sv2+S(68),BY+S(44),"---",             CLR_BUY,  FS(7),"Arial Bold");
   CreateLabel(g_prefix+"VS_STL",sv2,      BY+S(58),"Status:",         CLR_LABEL,FS(7));
   CreateLabel(g_prefix+"VS_STV",sv2+S(68),BY+S(58),"CHECKING",       CLR_WARN, FS(8),"Arial Bold");

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| UPDATE POSITIONS TABLE                                           |
//+------------------------------------------------------------------+
void UpdateTable()
{
   for(int r=0;r<12;r++){
      for(int c=0;c<9;c++) SetTxt(g_prefix+"TR_"+IntegerToString(r)+"_"+IntegerToString(c),"");
      SetBG(g_prefix+"TR_SEL_"+IntegerToString(r),CLR_BTN);
      SetClr(g_prefix+"TR_SEL_"+IntegerToString(r),CLR_LABEL);
   }
   int row=0;
   for(int i=0;i<PositionsTotal()&&row<12;i++){
      if(!g_position.SelectByIndex(i)) continue;
      ulong tk=g_position.Ticket();
      bool sel=(tk==g_state.selectedTicket&&!g_state.selectedIsPending);
      double pnl=g_position.Profit()+g_position.Swap()+g_position.Commission();
      string rs=IntegerToString(row);
      SetTxt(g_prefix+"TR_"+rs+"_0",IntegerToString((long)tk));
      SetTxt(g_prefix+"TR_"+rs+"_1",g_position.Symbol());
      SetTxt(g_prefix+"TR_"+rs+"_2",g_position.PositionType()==POSITION_TYPE_BUY?"BUY":"SELL");
      SetTxt(g_prefix+"TR_"+rs+"_3",FmtLot(g_position.Volume()));
      SetTxt(g_prefix+"TR_"+rs+"_4",FmtPrice(g_position.PriceOpen()));
      SetTxt(g_prefix+"TR_"+rs+"_5",FmtPrice(g_position.PriceCurrent()));
      SetTxt(g_prefix+"TR_"+rs+"_6",FmtPrice(g_position.StopLoss()));
      SetTxt(g_prefix+"TR_"+rs+"_7",FmtPrice(g_position.TakeProfit()));
      SetTxt(g_prefix+"TR_"+rs+"_8","$"+DoubleToString(pnl,2));
      color rowC=sel?CLR_WARN:CLR_VALUE;
      for(int c=0;c<8;c++) SetClr(g_prefix+"TR_"+rs+"_"+IntegerToString(c),rowC);
      SetClr(g_prefix+"TR_"+rs+"_8",pnl>=0?CLR_BUY:CLR_SELL);
      if(sel){ SetBG(g_prefix+"TR_SEL_"+rs,CLR_SELBTN); SetClr(g_prefix+"TR_SEL_"+rs,CLR_WARN); }
      row++;
   }
   for(int i=0;i<OrdersTotal()&&row<12;i++){
      if(!g_order.SelectByIndex(i)) continue;
      ulong tk=g_order.Ticket();
      bool sel=(tk==g_state.selectedTicket&&g_state.selectedIsPending);
      string rs=IntegerToString(row);
      string ot="";
      switch(g_order.OrderType()){
         case ORDER_TYPE_BUY_LIMIT:  ot="BUY LMT"; break;
         case ORDER_TYPE_SELL_LIMIT: ot="SLL LMT"; break;
         case ORDER_TYPE_BUY_STOP:   ot="BUY STP"; break;
         case ORDER_TYPE_SELL_STOP:  ot="SLL STP"; break;
         default: ot="PEND"; break;
      }
      SetTxt(g_prefix+"TR_"+rs+"_0",IntegerToString((long)tk));
      SetTxt(g_prefix+"TR_"+rs+"_1",g_order.Symbol());
      SetTxt(g_prefix+"TR_"+rs+"_2",ot);
      SetTxt(g_prefix+"TR_"+rs+"_3",FmtLot(g_order.VolumeInitial()));
      SetTxt(g_prefix+"TR_"+rs+"_4",FmtPrice(g_order.PriceOpen()));
      SetTxt(g_prefix+"TR_"+rs+"_5","PENDING");
      SetTxt(g_prefix+"TR_"+rs+"_6",FmtPrice(g_order.StopLoss()));
      SetTxt(g_prefix+"TR_"+rs+"_7",FmtPrice(g_order.TakeProfit()));
      SetTxt(g_prefix+"TR_"+rs+"_8","---");
      color rowC=sel?CLR_WARN:CLR_LABEL;
      for(int c=0;c<9;c++) SetClr(g_prefix+"TR_"+rs+"_"+IntegerToString(c),rowC);
      if(sel){ SetBG(g_prefix+"TR_SEL_"+rs,CLR_SELBTN); SetClr(g_prefix+"TR_SEL_"+rs,CLR_WARN); }
      row++;
   }
   if(g_state.selectedTicket>0)
      SetTxt(g_prefix+"MOD_SEL","Selected: #"+IntegerToString((long)g_state.selectedTicket)+
         (g_state.selectedIsPending?" (pending)":" (position) — Edit fields then MODIFY"));
   else
      SetTxt(g_prefix+"MOD_SEL","No trade selected — click SEL to select");
}

//+------------------------------------------------------------------+
//| UPDATE PRE-EXECUTION VERIFICATION PANEL                         |
//+------------------------------------------------------------------+
void UpdatePreExecPanel()
{
   bool isBuy=OrderIsBuy(g_state.orderType);
   string dirLabel=isBuy?"▲ BUY":"▼ SELL";
   color  dirClr  =isBuy?CLR_BUY:CLR_SELL;
   SetTxt(g_prefix+"PREV_DIR","Direction: "+dirLabel+"  |  Type: "+g_ddLabels[(int)g_state.orderType]);
   SetClr(g_prefix+"PREV_DIR",dirClr);
   SetTxt(g_prefix+"PREV_EV",FmtPrice(g_state.entryPrice));
   SetTxt(g_prefix+"PREV_SV",FmtPrice(g_state.computedSL));
   SetTxt(g_prefix+"PREV_TV",FmtPrice(g_state.computedTP>0?g_state.computedTP:0));
   // Sanity check
   string errMsg="";
   bool sane=SanityCheckStops(isBuy,g_state.entryPrice,g_state.computedSL,g_state.computedTP,errMsg);
   if(sane){
      SetTxt(g_prefix+"PREV_OK","✔ SL/TP OK"); SetClr(g_prefix+"PREV_OK",CLR_VALID);
   } else {
      SetTxt(g_prefix+"PREV_OK","✖ "+errMsg); SetClr(g_prefix+"PREV_OK",CLR_INVALID);
   }
}

//+------------------------------------------------------------------+
//| UPDATE DASHBOARD                                                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| UPDATE NEWS DISPLAY — called from UpdateDashboard and OnTick    |
//+------------------------------------------------------------------+
void UpdateNewsDisplay()
{
   // Per-field parse status
   datetime blk_chk = (datetime)(NEWS_BLOCK_MINS*60);
   for(int i=0;i<3;i++){
      string ns=g_state.newsStr[i];
      StringTrimRight(ns); StringTrimLeft(ns);
      string psName=g_prefix+"NEWS_PS"+IntegerToString(i);
      if(ns==""||ns=="DD-MM-YYYY HH:MM"){
         SetTxt(psName,"(empty)"); SetClr(psName,CLR_LABEL);
      } else if(g_state.newsTime[i]>0){
         // newsTime[i] is stored as IST; now_chk is server→IST
         datetime now_ist = TimeLocal();
         datetime wEnd    = g_state.newsTime[i] + blk_chk;
         MqlDateTime d; TimeToStruct(g_state.newsTime[i],d);
         if(wEnd < now_ist){
            // Block window fully passed — tell user to update the date/time
            SetTxt(psName,StringFormat("⚠ PAST — %02d-%02d-%04d %02d:%02d IST (update!)",
                   d.day,d.mon,d.year,d.hour,d.min));
            SetClr(psName,CLR_WARN2);
         } else {
            // Active or future — confirm the parsed IST time
            SetTxt(psName,StringFormat("✔ %02d-%02d-%04d %02d:%02d IST",
                   d.day,d.mon,d.year,d.hour,d.min));
            SetClr(psName,CLR_VALID);
         }
      } else {
         SetTxt(psName,"✖ Invalid — use DD-MM-YYYY HH:MM");
         SetClr(psName,CLR_INVALID);
      }
   }

   if(g_state.newsBlocking)
   {
      // ── ACTIVE BLOCK ──────────────────────────────────────────────
      SetTxt(g_prefix+"NEWS_STAT","● NEWS BLOCK ACTIVE — Trading disabled");
      SetClr(g_prefix+"NEWS_STAT",CLR_NEWS);
      SetTxt(g_prefix+"NEWS_NEXT", g_state.newsNextLabel);
      SetClr(g_prefix+"NEWS_NEXT", CLR_NEWS);
      SetTxt(g_prefix+"NEWS_CNTD", g_state.newsCountdown);
      SetClr(g_prefix+"NEWS_CNTD", CLR_INVALID);
      // Large warning labels
      SetTxt(g_prefix+"NEWS_WARN",  "⚠  NEWS TIME — NO TRADE  ⚠");
      SetClr(g_prefix+"NEWS_WARN",  CLR_NEWS);
      SetTxt(g_prefix+"NEWS_WARN2", "NEWS FILTER ACTIVE — TRADING DISABLED");
      SetClr(g_prefix+"NEWS_WARN2", CLR_INVALID);
   }
   else if(g_state.newsUpcoming)
   {
      // ── UPCOMING (within 60 min) ──────────────────────────────────
      SetTxt(g_prefix+"NEWS_STAT","⚠ News event approaching — prepare");
      SetClr(g_prefix+"NEWS_STAT",CLR_WARN);
      SetTxt(g_prefix+"NEWS_NEXT", g_state.newsNextLabel);
      SetClr(g_prefix+"NEWS_NEXT", CLR_WARN);
      SetTxt(g_prefix+"NEWS_CNTD", g_state.newsCountdown);
      SetClr(g_prefix+"NEWS_CNTD", CLR_WARN);
      SetTxt(g_prefix+"NEWS_WARN"," ");
      SetTxt(g_prefix+"NEWS_WARN2"," ");
   }
   else if(g_state.newsNextLabel != "")
   {
      // ── FUTURE EVENT KNOWN ────────────────────────────────────────
      SetTxt(g_prefix+"NEWS_STAT","○ No active block");
      SetClr(g_prefix+"NEWS_STAT",CLR_LABEL);
      SetTxt(g_prefix+"NEWS_NEXT", g_state.newsNextLabel);
      SetClr(g_prefix+"NEWS_NEXT", CLR_LABEL);
      SetTxt(g_prefix+"NEWS_CNTD","");
      SetTxt(g_prefix+"NEWS_WARN"," ");
      SetTxt(g_prefix+"NEWS_WARN2"," ");
   }
   else
   {
      // ── NO FUTURE EVENTS ─────────────────────────────────────────
      // Check if any fields have entries (even if past)
      bool anySet=false;
      for(int i=0;i<3;i++){
         string ns=g_state.newsStr[i];
         StringTrimRight(ns); StringTrimLeft(ns);
         if(ns!=""&&ns!="DD-MM-YYYY HH:MM") { anySet=true; break; }
      }
      if(anySet)
         SetTxt(g_prefix+"NEWS_STAT","○ All configured events are in the past — update dates");
      else
         SetTxt(g_prefix+"NEWS_STAT","○ No news events configured");
      SetClr(g_prefix+"NEWS_STAT",CLR_LABEL);
      SetTxt(g_prefix+"NEWS_NEXT","");
      SetTxt(g_prefix+"NEWS_CNTD","");
      SetTxt(g_prefix+"NEWS_WARN"," ");
      SetTxt(g_prefix+"NEWS_WARN2"," ");
   }
}

void UpdateDashboard()
{
   SetTxt(g_prefix+"TITLE",
      "MT5 MANUAL TRADING DASHBOARD  |  "+_Symbol+
      "  ASK:"+FmtPrice(g_state.ask)+"  BID:"+FmtPrice(g_state.bid));
   MqlDateTime srv,loc;
   TimeToStruct(TimeCurrent(),srv); TimeToStruct(TimeLocal(),loc);
   SetTxt(g_prefix+"SRVTIME",StringFormat("SRV:%02d:%02d:%02d",srv.hour,srv.min,srv.sec));
   SetTxt(g_prefix+"LOCTIME",StringFormat("LOC:%02d:%02d:%02d",loc.hour,loc.min,loc.sec));
   // Account
   SetTxt(g_prefix+"AV_BAL", "$"+DoubleToString(g_state.accountBalance,2));
   SetTxt(g_prefix+"AV_EQ",  "$"+DoubleToString(g_state.accountEquity,2));
   SetTxt(g_prefix+"AV_LEV", "1:"+IntegerToString(g_state.accountLeverage));
   SetTxt(g_prefix+"AV_UMGN","$"+DoubleToString(g_state.usedMargin,2));
   SetTxt(g_prefix+"AV_SPR", IntegerToString((int)g_state.currentSpread)+"/"+IntegerToString(g_state.maxSpread));
   SetClr(g_prefix+"AV_SPR", g_state.spreadOk?CLR_VALUE:CLR_INVALID);
   // SL/TP display
   SetTxt(g_prefix+"BTN_SLMD",g_state.slMode==SL_PIPS?"PIPS":"PRICE");
   SetTxt(g_prefix+"BTN_TPMD",g_state.tpMode==TP_PIPS?"PIPS":"PRICE");
   bool isBuy=OrderIsBuy(g_state.orderType);
   SetTxt(g_prefix+"SL_CALC","SL: "+FmtPrice(g_state.computedSL)+(isBuy?" (below entry)":" (above entry)"));
   SetClr(g_prefix+"SL_CALC",CLR_SELL);
   string rrS=g_state.riskRewardRatio>0?"  RR:1:"+DoubleToString(g_state.riskRewardRatio,2):"  RR:---";
   SetTxt(g_prefix+"TP_CALC","TP: "+FmtPrice(g_state.computedTP)+(isBuy?" (above entry)":" (below entry)")+rrS);
   SetClr(g_prefix+"TP_CALC",CLR_BUY);
   bool isPend=(g_state.orderType!=OTYPE_MARKET_BUY&&g_state.orderType!=OTYPE_MARKET_SELL);
   SetTxt(g_prefix+"PEND_NOTE",isPend?"Required for pending order":"Not used for market orders");
   // Dropdown label
   SetTxt(g_prefix+"BTN_DD",g_ddLabels[(int)g_state.orderType]+"  ▼");
   // Lot
   SetTxt(g_prefix+"LOT_VAL",FmtLot(g_state.calculatedLotSize)+" lots");
   SetClr(g_prefix+"LOT_VAL",(g_state.leverageOk&&g_state.calculatedLotSize>0)?CLR_VALUE:CLR_INVALID);
   SetTxt(g_prefix+"LOT_NOTE",isPend?"fixed at entry price":"live (locks on click)");
   SetTxt(g_prefix+"LOT_MXLOT","Max:"+FmtLot(g_state.maxAllowedLot));
   // BUY button enabled only for buy-direction order types
   // SELL button enabled only for sell-direction order types
   bool buyEnabled  = g_state.isValid && isBuy;
   bool sellEnabled = g_state.isValid && !isBuy;
   SetBtnEnabled(g_prefix+"BTN_BUY", buyEnabled, CLR_BUY);
   SetBtnEnabled(g_prefix+"BTN_SELL",sellEnabled,CLR_SELL);
   // Validation
   if(g_state.isValid){
      SetTxt(g_prefix+"VAL_STATUS","✔ VALID"); SetClr(g_prefix+"VAL_STATUS",CLR_VALID);
      SetTxt(g_prefix+"VS_STV","✔ VALID");    SetClr(g_prefix+"VS_STV",CLR_VALID);
   } else {
      SetTxt(g_prefix+"VAL_STATUS","✖ "+g_state.validationMessage);
      SetClr(g_prefix+"VAL_STATUS",CLR_INVALID);
      SetTxt(g_prefix+"VS_STV","✖ INVALID"); SetClr(g_prefix+"VS_STV",CLR_INVALID);
   }
   // Max lot / margin
   SetTxt(g_prefix+"ML_LV",FmtLot(g_state.maxLotByLeverage)+" lots");
   SetTxt(g_prefix+"ML_MV",FmtLot(g_state.maxLotByMargin)  +" lots");
   SetTxt(g_prefix+"ML_FV",FmtLot(g_state.maxAllowedLot)   +" lots");
   SetTxt(g_prefix+"MB_AV",FmtMoney(g_state.maxMarginAllowed));
   SetTxt(g_prefix+"MB_UV",FmtMoney(g_state.marginAlreadyUsed));
   SetTxt(g_prefix+"MB_RV",FmtMoney(g_state.remainingMarginAvail));
   SetTxt(g_prefix+"ML_WARN",
      (!g_state.leverageOk&&g_state.calculatedLotSize>0)
      ?"⚠ Lot ("+FmtLot(g_state.calculatedLotSize)+") > cap ("+FmtLot(g_state.maxAllowedLot)+")"
      :"");
   // Validation summary
   SetTxt(g_prefix+"VS_RV",FmtMoney(g_state.tradeRisk));
   SetTxt(g_prefix+"VS_LV",FmtLot(g_state.calculatedLotSize)+" lots");
   SetClr(g_prefix+"VS_LV",(g_state.leverageOk&&g_state.calculatedLotSize>0)?CLR_VALUE:CLR_INVALID);
   SetTxt(g_prefix+"VS_MV",FmtMoney(g_state.marginRequired));
   SetTxt(g_prefix+"VS_XV",FmtLot(g_state.maxAllowedLot)+" lots");
   SetTxt(g_prefix+"VS_RRV",g_state.riskRewardRatio>0?"1:"+DoubleToString(g_state.riskRewardRatio,2):"---");
   SetTxt(g_prefix+"VS_SLV",FmtPrice(g_state.computedSL));
   SetTxt(g_prefix+"VS_TPV",FmtPrice(g_state.computedTP>0?g_state.computedTP:0));
   // News display
   UpdateNewsDisplay();
   UpdatePreExecPanel();
   UpdateTable();
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| DROPDOWN                                                          |
//+------------------------------------------------------------------+
void ToggleDropdown(bool open)
{
   g_dropdownOpen=open;
   for(int i=0;i<6;i++) SetVis(g_prefix+"DD_"+IntegerToString(i),open);
   SetBG(g_prefix+"BTN_DD",open?C'72,72,128':CLR_DDOPEN);
   ChartRedraw();
}
void SelectOrderType(int idx)
{
   g_state.orderType=(ENUM_DASH_ORDERTYPE)idx;
   ToggleDropdown(false);
   bool isPend=(g_state.orderType!=OTYPE_MARKET_BUY&&g_state.orderType!=OTYPE_MARKET_SELL);
   if(isPend&&g_state.pendingPrice>0) AutoFillPendingSL();
   UpdateState(); UpdateDashboard();
}

//+------------------------------------------------------------------+
//| SELECT TRADE                                                      |
//+------------------------------------------------------------------+
void SelectTradeByTicket(ulong ticket)
{
   if(ticket==0) return;
   bool found=false,isPend=false;
   for(int i=0;i<PositionsTotal();i++)
      if(g_position.SelectByIndex(i)&&g_position.Ticket()==ticket){ found=true; isPend=false; break; }
   if(!found)
      for(int i=0;i<OrdersTotal();i++)
         if(g_order.SelectByIndex(i)&&g_order.Ticket()==ticket){ found=true; isPend=true; break; }
   if(!found){ g_state.selectedTicket=0; g_state.selectedIsPending=false; return; }
   if(g_state.selectedTicket==ticket){
      g_state.selectedTicket=0; g_state.selectedIsPending=false;
      PutEdit(g_prefix+"ED_NSL",""); PutEdit(g_prefix+"ED_NTP","");
   } else {
      g_state.selectedTicket=ticket; g_state.selectedIsPending=isPend;
      double cSL=0,cTP=0;
      if(!isPend){ if(g_position.SelectByTicket(ticket)){ cSL=g_position.StopLoss(); cTP=g_position.TakeProfit(); } }
      else       { if(g_order.Select(ticket))            { cSL=g_order.StopLoss();    cTP=g_order.TakeProfit();   } }
      PutEdit(g_prefix+"ED_NSL",cSL>0?FmtPrice(cSL):"");
      PutEdit(g_prefix+"ED_NTP",cTP>0?FmtPrice(cTP):"");
   }
}

//+------------------------------------------------------------------+
//| TRADE EXECUTION                                                   |
//|  Direction is determined SOLELY by orderType.                   |
//|  BUY button can only fire when orderType is a Buy type.         |
//|  SELL button can only fire when orderType is a Sell type.       |
//|  No direction-swapping occurs anywhere — direction is baked in. |
//+------------------------------------------------------------------+
bool ExecuteTrade()
{
   if(!g_state.isValid) return false;

   bool isBuy = OrderIsBuy(g_state.orderType);

   // Snapshot all values at this exact moment
   double lockedLot = g_state.calculatedLotSize;
   double lockedSL  = g_state.computedSL;
   double lockedTP  = g_state.computedTP;
   int    splits    = g_state.splitCount;

   if(lockedLot<=0) return false;

   // Pre-execution sanity check
   string sanityErr="";
   if(!SanityCheckStops(isBuy,g_state.entryPrice,lockedSL,lockedTP,sanityErr)){
      Print("EXECUTION BLOCKED — Stop sanity check failed: ",sanityErr);
      Print("  isBuy=",isBuy,"  entryPx=",g_state.entryPrice,
            "  ask=",g_state.ask,"  bid=",g_state.bid,
            "  SL=",lockedSL,"  TP=",lockedTP);
      return false;
   }

   double splitLot=NormalizeLot(lockedLot/splits);
   if(splitLot<g_state.minLot){ Print("Split lot too small: ",splitLot); return false; }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);

   bool anyOk=false;
   for(int s=0;s<splits;s++){
      bool ok=false;
      // Get fresh prices at moment of order submission
      double execAsk=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double execBid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

      PrintFormat("Submitting [%s] lot=%.2f SL=%.5f TP=%.5f ask=%.5f bid=%.5f",
                  isBuy?"BUY":"SELL",splitLot,lockedSL,lockedTP,execAsk,execBid);

      switch(g_state.orderType){
         case OTYPE_MARKET_BUY:
            ok=g_trade.Buy(splitLot,_Symbol,execAsk,lockedSL,lockedTP,InpTradeComment);
            break;
         case OTYPE_MARKET_SELL:
            ok=g_trade.Sell(splitLot,_Symbol,execBid,lockedSL,lockedTP,InpTradeComment);
            break;
         case OTYPE_BUY_LIMIT:{
            double pp=g_state.pendingPrice>0?g_state.pendingPrice:execAsk;
            ok=g_trade.BuyLimit(splitLot,pp,_Symbol,lockedSL,lockedTP,ORDER_TIME_GTC,0,InpTradeComment);
            break;}
         case OTYPE_SELL_LIMIT:{
            double pp=g_state.pendingPrice>0?g_state.pendingPrice:execBid;
            ok=g_trade.SellLimit(splitLot,pp,_Symbol,lockedSL,lockedTP,ORDER_TIME_GTC,0,InpTradeComment);
            break;}
         case OTYPE_BUY_STOP:{
            double pp=g_state.pendingPrice>0?g_state.pendingPrice:execAsk;
            ok=g_trade.BuyStop(splitLot,pp,_Symbol,lockedSL,lockedTP,ORDER_TIME_GTC,0,InpTradeComment);
            break;}
         case OTYPE_SELL_STOP:{
            double pp=g_state.pendingPrice>0?g_state.pendingPrice:execBid;
            ok=g_trade.SellStop(splitLot,pp,_Symbol,lockedSL,lockedTP,ORDER_TIME_GTC,0,InpTradeComment);
            break;}
      }
      if(ok){
         anyOk=true;
         bool isPend=(g_state.orderType!=OTYPE_MARKET_BUY&&g_state.orderType!=OTYPE_MARKET_SELL);
         if(isPend) PutEdit(g_prefix+"ED_PEND","");
      } else {
         Print("Order error [split ",s+1,"]: ",g_trade.ResultRetcodeDescription(),
               " retcode=",g_trade.ResultRetcode());
      }
   }
   return anyOk;
}

//+------------------------------------------------------------------+
//| TRADE MANAGEMENT (logic unchanged)                               |
//+------------------------------------------------------------------+
void CloseSelectedTrade()
{
   if(g_state.selectedTicket==0||g_state.selectedIsPending) return;
   g_trade.PositionClose(g_state.selectedTicket);
}
void CloseAllTrades()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(g_position.SelectByIndex(i)) g_trade.PositionClose(g_position.Ticket());
}
void CloseAllProfitable()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(g_position.SelectByIndex(i)){
         double p=g_position.Profit()+g_position.Swap()+g_position.Commission();
         if(p>0) g_trade.PositionClose(g_position.Ticket());
      }
}
void CloseAllLosing()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(g_position.SelectByIndex(i)){
         double p=g_position.Profit()+g_position.Swap()+g_position.Commission();
         if(p<0) g_trade.PositionClose(g_position.Ticket());
      }
}
void MoveBreakevenSelected()
{
   if(g_state.selectedTicket==0||g_state.selectedIsPending) return;
   if(g_position.SelectByTicket(g_state.selectedTicket))
      g_trade.PositionModify(g_state.selectedTicket,g_position.PriceOpen(),g_position.TakeProfit());
}
void MoveBreakevenAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(g_position.SelectByIndex(i))
         g_trade.PositionModify(g_position.Ticket(),g_position.PriceOpen(),g_position.TakeProfit());
}
void ModifySelectedTrade()
{
   if(g_state.selectedTicket==0){ Print("Modify: no trade selected"); return; }
   string nslT=GetEdit(g_prefix+"ED_NSL"), ntpT=GetEdit(g_prefix+"ED_NTP");
   if(!g_state.selectedIsPending){
      if(!g_position.SelectByTicket(g_state.selectedTicket)){ g_state.selectedTicket=0; return; }
      double nSL=(nslT!=""&&StringToDouble(nslT)>0)?StringToDouble(nslT):g_position.StopLoss();
      double nTP=(ntpT!=""&&StringToDouble(ntpT)>0)?StringToDouble(ntpT):g_position.TakeProfit();
      if(g_trade.PositionModify(g_state.selectedTicket,nSL,nTP))
      { PutEdit(g_prefix+"ED_NSL",""); PutEdit(g_prefix+"ED_NTP",""); }
      else Print("Modify error: ",g_trade.ResultRetcodeDescription());
   } else {
      if(!g_order.Select(g_state.selectedTicket)){ g_state.selectedTicket=0; return; }
      double nSL=(nslT!=""&&StringToDouble(nslT)>0)?StringToDouble(nslT):g_order.StopLoss();
      double nTP=(ntpT!=""&&StringToDouble(ntpT)>0)?StringToDouble(ntpT):g_order.TakeProfit();
      if(g_trade.OrderModify(g_state.selectedTicket,g_order.PriceOpen(),nSL,nTP,ORDER_TIME_GTC,0))
      { PutEdit(g_prefix+"ED_NSL",""); PutEdit(g_prefix+"ED_NTP",""); }
      else Print("OrderModify error: ",g_trade.ResultRetcodeDescription());
   }
}
void CancelSelectedPending()
{
   if(g_state.selectedTicket==0||!g_state.selectedIsPending) return;
   g_trade.OrderDelete(g_state.selectedTicket); g_state.selectedTicket=0;
}
void CancelAllPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
      if(g_order.SelectByIndex(i)) g_trade.OrderDelete(g_order.Ticket());
   g_state.selectedTicket=0;
}
void EmergencyKillSwitch(){ CloseAllTrades(); CancelAllPending(); Print("EMERGENCY KILL SWITCH ACTIVATED."); }

//+------------------------------------------------------------------+
//| ZOOM                                                              |
//+------------------------------------------------------------------+
void ApplyZoom(double nz)
{
   nz=MathMax(0.6,MathMin(2.0,nz));
   if(MathAbs(nz-g_zoom)<0.001) return;
   g_zoom=nz;
   DestroyDashboard(); BuildDashboard(); UpdateState(); UpdateDashboard();
}
void DestroyDashboard()
{
   int sz=ArraySize(g_allObjects);
   for(int i=0;i<sz;i++) if(ObjectFind(0,g_allObjects[i])>=0) ObjectDelete(0,g_allObjects[i]);
   ArrayResize(g_allObjects,0);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| INIT STATE                                                       |
//+------------------------------------------------------------------+
void InitState()
{
   g_state.tradeRisk        =InpTradeRisk;
   g_state.allowedLeverage  =InpAllowedLeverage;
   g_state.maxMarginAllowed =InpMaxMargin;
   g_state.maxSpread        =InpMaxSpread;
   g_state.splitCount       =MathMax(1,MathMin(3,InpSplitTrades));
   g_state.maxPositions     =MathMax(1,InpMaxPositions);
   g_state.slMode           =SL_PIPS; g_state.tpMode=TP_PIPS;
   g_state.slPips           =InpSLPips; g_state.tpPips=InpTPPips;
   g_state.slPrice          =0; g_state.tpPrice=0; g_state.pendingPrice=0;
   g_state.orderType        =OTYPE_MARKET_BUY;
   g_state.entryPrice       =0;
   g_state.selectedTicket   =0; g_state.selectedIsPending=false;
   g_state.isValid          =false;
   g_state.digits           =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_state.newsBlocking     =false; g_state.newsBlockMsg="";
   g_state.newsNextLabel=""; g_state.newsCountdown=""; g_state.newsUpcoming=false;
   for(int i=0;i<3;i++){ g_state.newsStr[i]=""; g_state.newsTime[i]=0; }
   g_zoom=1.0;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   PNL_X=InpPanelX; PNL_Y=InpPanelY;
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(20);
   g_trade.LogLevel(LOG_LEVEL_ALL);   // Full logging for diagnostics
   InitState();
   BuildDashboard();
   UpdateState();
   UpdateDashboard();
   EventSetTimer(1);
   Print("ManualTradingDashboard v6.60 initialized on ",_Symbol);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){ EventKillTimer(); DestroyDashboard(); }
void OnTimer(){ UpdateState(); UpdateDashboard(); }

//+------------------------------------------------------------------+
//| OnTick — live lot and SL/TP refresh every tick                  |
//+------------------------------------------------------------------+
void OnTick()
{
   g_state.ask          =SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   g_state.bid          =SymbolInfoDouble(_Symbol,SYMBOL_BID);
   g_state.currentSpread=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   g_state.spreadOk     =(g_state.currentSpread<=g_state.maxSpread);
   UpdateState();  // full recalc including lot and SL/TP
   // Fast label refresh
   SetTxt(g_prefix+"TITLE",
      "MT5 MANUAL TRADING DASHBOARD  |  "+_Symbol+
      "  ASK:"+FmtPrice(g_state.ask)+"  BID:"+FmtPrice(g_state.bid));
   SetTxt(g_prefix+"LOT_VAL",FmtLot(g_state.calculatedLotSize)+" lots");
   SetClr(g_prefix+"LOT_VAL",(g_state.leverageOk&&g_state.calculatedLotSize>0)?CLR_VALUE:CLR_INVALID);
   bool isBuy=OrderIsBuy(g_state.orderType);
   SetTxt(g_prefix+"SL_CALC","SL: "+FmtPrice(g_state.computedSL)+(isBuy?" (below)":" (above)"));
   SetTxt(g_prefix+"TP_CALC","TP: "+FmtPrice(g_state.computedTP>0?g_state.computedTP:0)+
      (isBuy?" (above)":" (below)")+
      (g_state.riskRewardRatio>0?"  RR:1:"+DoubleToString(g_state.riskRewardRatio,2):"  RR:---"));
   SetTxt(g_prefix+"AV_SPR",
      IntegerToString((int)g_state.currentSpread)+"/"+IntegerToString(g_state.maxSpread));
   SetClr(g_prefix+"AV_SPR",g_state.spreadOk?CLR_VALUE:CLR_INVALID);
   // Max lot live
   SetTxt(g_prefix+"ML_LV",FmtLot(g_state.maxLotByLeverage)+" lots");
   SetTxt(g_prefix+"ML_MV",FmtLot(g_state.maxLotByMargin)  +" lots");
   SetTxt(g_prefix+"ML_FV",FmtLot(g_state.maxAllowedLot)   +" lots");
   SetTxt(g_prefix+"MB_UV",FmtMoney(g_state.marginAlreadyUsed));
   SetTxt(g_prefix+"MB_RV",FmtMoney(g_state.remainingMarginAvail));
   // Validation + buttons
   bool buyEnabled =g_state.isValid&&isBuy;
   bool sellEnabled=g_state.isValid&&!isBuy;
   SetBtnEnabled(g_prefix+"BTN_BUY", buyEnabled, CLR_BUY);
   SetBtnEnabled(g_prefix+"BTN_SELL",sellEnabled,CLR_SELL);
   if(g_state.isValid){
      SetTxt(g_prefix+"VAL_STATUS","✔ VALID"); SetClr(g_prefix+"VAL_STATUS",CLR_VALID);
      SetTxt(g_prefix+"VS_STV","✔ VALID");    SetClr(g_prefix+"VS_STV",CLR_VALID);
   } else {
      SetTxt(g_prefix+"VAL_STATUS","✖ "+g_state.validationMessage);
      SetClr(g_prefix+"VAL_STATUS",CLR_INVALID);
      SetTxt(g_prefix+"VS_STV","✖ INVALID"); SetClr(g_prefix+"VS_STV",CLR_INVALID);
   }
   SetTxt(g_prefix+"VS_LV", FmtLot(g_state.calculatedLotSize)+" lots");
   SetTxt(g_prefix+"VS_SLV",FmtPrice(g_state.computedSL));
   SetTxt(g_prefix+"VS_TPV",FmtPrice(g_state.computedTP>0?g_state.computedTP:0));
   // Pre-exec panel
   UpdatePreExecPanel();
   // News
   UpdateNewsDisplay();
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnChartEvent                                                     |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long   &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK)
   {
      ResetBtn(sparam);  // release immediately → single-click guaranteed

      if(g_dropdownOpen&&sparam!=g_prefix+"BTN_DD"&&StringFind(sparam,g_prefix+"DD_")<0)
         ToggleDropdown(false);

      // Zoom
      if(sparam==g_prefix+"BTN_ZM"){ ApplyZoom(g_zoom-0.1); return; }
      if(sparam==g_prefix+"BTN_ZP"){ ApplyZoom(g_zoom+0.1); return; }

      // Dropdown
      if(sparam==g_prefix+"BTN_DD"){ ToggleDropdown(!g_dropdownOpen); return; }
      for(int i=0;i<6;i++)
         if(sparam==g_prefix+"DD_"+IntegerToString(i)){ SelectOrderType(i); return; }

      // SL/TP mode
      if(sparam==g_prefix+"BTN_SLMD"){
         g_state.slMode=(g_state.slMode==SL_PIPS)?SL_PRICE:SL_PIPS;
         PutEdit(g_prefix+"ED_SL",g_state.slMode==SL_PRICE?FmtPrice(g_state.computedSL):IntegerToString(g_state.slPips));
         UpdateState(); UpdateDashboard(); return;
      }
      if(sparam==g_prefix+"BTN_TPMD"){
         g_state.tpMode=(g_state.tpMode==TP_PIPS)?TP_PRICE:TP_PIPS;
         PutEdit(g_prefix+"ED_TP",g_state.tpMode==TP_PRICE?FmtPrice(g_state.computedTP):IntegerToString(g_state.tpPips));
         UpdateState(); UpdateDashboard(); return;
      }

      // BUY — only fires when orderType is a Buy type
      if(sparam==g_prefix+"BTN_BUY"){
         bool isBuy=OrderIsBuy(g_state.orderType);
         if(!isBuy){ Print("BUY button pressed but order type is Sell — ignored"); return; }
         if(g_state.isValid){ ExecuteTrade(); UpdateState(); UpdateDashboard(); }
         else Print("BUY rejected: ",g_state.validationMessage);
         return;
      }

      // SELL — only fires when orderType is a Sell type
      if(sparam==g_prefix+"BTN_SELL"){
         bool isBuy=OrderIsBuy(g_state.orderType);
         if(isBuy){ Print("SELL button pressed but order type is Buy — ignored"); return; }
         if(g_state.isValid){ ExecuteTrade(); UpdateState(); UpdateDashboard(); }
         else Print("SELL rejected: ",g_state.validationMessage);
         return;
      }

      // Management
      if(sparam==g_prefix+"BTN_CSEL") { CloseSelectedTrade();    UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_CALL") { CloseAllTrades();        UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_CPROF"){ CloseAllProfitable();    UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_CLOSS"){ CloseAllLosing();        UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_BESEL"){ MoveBreakevenSelected(); UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_BEALL"){ MoveBreakevenAll();      UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_MOD")  { ModifySelectedTrade();   UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_CPOS") { CancelSelectedPending(); UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_CAPO") { CancelAllPending();      UpdateState(); UpdateDashboard(); return; }
      if(sparam==g_prefix+"BTN_KILL") { EmergencyKillSwitch();   UpdateState(); UpdateDashboard(); return; }

      // Table SEL
      for(int r=0;r<12;r++){
         if(sparam==g_prefix+"TR_SEL_"+IntegerToString(r)){
            string ts=ObjectGetString(0,g_prefix+"TR_"+IntegerToString(r)+"_0",OBJPROP_TEXT);
            if(ts!=""&&StringToInteger(ts)>0){
               SelectTradeByTicket((ulong)StringToInteger(ts));
               UpdateDashboard();
            }
            return;
         }
      }
   }

   if(id==CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(sparam==g_prefix+"ED_PEND"){
         string ps=GetEdit(g_prefix+"ED_PEND");
         if(ps!="") g_state.pendingPrice=StringToDouble(ps);
         bool isPend=(g_state.orderType!=OTYPE_MARKET_BUY&&g_state.orderType!=OTYPE_MARKET_SELL);
         if(isPend) AutoFillPendingSL();
      }
      UpdateState(); UpdateDashboard();
   }

   if(id==CHARTEVENT_KEYDOWN)
   {
      int key=(int)lparam;
      // B = force Market Buy and execute
      if(key==66){ g_state.orderType=OTYPE_MARKET_BUY; UpdateState();
                   if(g_state.isValid){ ExecuteTrade(); UpdateState(); UpdateDashboard(); } }
      // S = force Market Sell and execute
      if(key==83){ g_state.orderType=OTYPE_MARKET_SELL; UpdateState();
                   if(g_state.isValid){ ExecuteTrade(); UpdateState(); UpdateDashboard(); } }
      // C = emergency kill
      if(key==67){ EmergencyKillSwitch(); UpdateState(); UpdateDashboard(); }
   }
}
//+------------------------------------------------------------------+
//| END OF FILE                                                       |
//+------------------------------------------------------------------+
