//+------------------------------------------------------------------+
//|                                                    CopySlave.mq4 |
//|                                                   MetaTraderCopy |
//+------------------------------------------------------------------+
//| SLAVE side of the MetaTraderCopy trade copier (MetaTrader 4).    |
//|                                                                  |
//| Attach this EA to ONE chart of every MT4 account that should     |
//| follow the master. It polls the signal file written by           |
//| CopyMaster (MT4 or MT5) in the terminal Common\Files folder and  |
//| mirrors the master's open trades on this account:                |
//|   * opens a copy when a new master trade appears                 |
//|   * closes the copy when the master trade disappears             |
//|   * partially closes / adds when the master volume changes       |
//|   * keeps SL/TP in sync (optional)                               |
//|                                                                  |
//| Copies are tagged with the magic number and the comment          |
//| "MC<master ticket>". The master->slave ticket mapping is         |
//| persisted to a file in the terminal's local Files folder so the  |
//| copier survives restarts (MT4 rewrites comments on partial       |
//| close, so the state file is the primary record).                 |
//+------------------------------------------------------------------+
#property copyright   "MetaTraderCopy"
#property link        "https://github.com/marcinzieba4-bot/MetaTraderCopy"
#property version     "1.00"
#property description "Slave side of the MetaTraderCopy trade copier."
#property description "Mirrors the trades published by CopyMaster onto this account."
#property strict

//--- lot sizing modes
enum ENUM_LOT_MODE
{
   LOT_MULTIPLIER = 0, // Master lots x multiplier
   LOT_FIXED      = 1, // Fixed lots
   LOT_BALANCE    = 2, // Master lots x (my balance / master balance) x multiplier
   LOT_EQUITY     = 3  // Master lots x (my equity / master equity) x multiplier
};
//--- SL/TP handling
enum ENUM_SLTP_MODE
{
   SLTP_NONE  = 0, // Do not copy SL/TP
   SLTP_PRICE = 1  // Copy SL/TP price levels and keep them in sync
};

//--- Signal source
input string          InpSignalFile      = "MTC_master.txt"; // Signal file name (Common\Files) - used when URL is empty
input string          InpSignalUrl       = "";               // Relay URL (master on another machine), e.g. https://relay.example.com/signal/mymaster
input string          InpApiKey          = "";               // Relay API key
input int             InpHttpTimeoutMs   = 2000;             // HTTP timeout, milliseconds
input long            InpMasterAccount   = 0;                // Expected master login (0 = accept any)
input int             InpPollMs          = 250;              // Poll interval, milliseconds
input int             InpMaxSignalAgeSec = 15;               // Signal older than this = master offline, seconds
input int             InpMaxTradeAgeSec  = 120;              // Copy only trades opened within N seconds (0 = copy all)
//--- Lot sizing
input ENUM_LOT_MODE   InpLotMode         = LOT_MULTIPLIER;   // Lot sizing mode
input double          InpLotMultiplier   = 1.0;              // Multiplier
input double          InpFixedLots       = 0.10;             // Fixed lots (LOT_FIXED mode)
input double          InpMaxLots         = 0.0;              // Max lots per copied trade (0 = symbol maximum)
//--- Execution
input int             InpMagic           = 776601;           // Magic number of copied trades
input int             InpSlippagePoints  = 30;               // Max slippage, points
input int             InpMaxSpreadPoints = 0;                // Skip opening if spread above N points (0 = off)
input ENUM_SLTP_MODE  InpSLTPMode        = SLTP_PRICE;       // SL/TP handling
input bool            InpReverse         = false;            // Reverse trades (buy <-> sell)
input bool            InpCloseWithMaster = true;             // Close copies when master closes
input int             InpMaxOpenAttempts = 3;                // Give up on a trade after N failed opens
//--- Symbol mapping
input string          InpMasterPrefix    = "";               // Prefix to strip from master symbols
input string          InpMasterSuffix    = "";               // Suffix to strip from master symbols (e.g. .m)
input string          InpSlavePrefix     = "";               // Prefix to add on this account
input string          InpSlaveSuffix     = "";               // Suffix to add on this account (e.g. .pro)
input string          InpSymbolMap       = "";               // Explicit map, e.g. XAUUSD=GOLD;US30=DJ30
input string          InpAllowedSymbols  = "";               // Copy only these master symbols (comma list, empty = all)

#define VOL_EPS 0.0000001

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct MasterPos
{
   long     ticket;
   string   symbol;
   int      type;      // 0 = buy, 1 = sell
   double   volume;
   double   price;
   double   sl;
   double   tp;
   datetime opentime;
};
struct Link
{
   long     master;
   int      slave;
   datetime retryAfter;
};
struct MState
{
   long     master;
   double   volume;
   string   symbol;
   int      type;
   datetime opentime;
   double   price;
};
struct Attempt
{
   long     master;
   int      count;
};

MasterPos g_master[];
Link      g_links[];
MState    g_state[];
Attempt   g_attempts[];
string    g_symFrom[];
string    g_symTo[];

long      g_masterLogin      = 0;
string    g_masterCurrency   = "";
double    g_masterBalance    = 0;
double    g_masterEquity     = 0;
datetime  g_masterServerTime = 0;
datetime  g_masterGmt        = 0;
string    g_masterPlatform   = "";
string    g_status           = "starting";
string    g_stateFile        = "";
bool      g_dirty            = false;
bool      g_busy             = false;
long      g_relayAge         = -1;      // signal age reported by the relay (-1 = not available)

//+------------------------------------------------------------------+
int OnInit()
{
   g_stateFile = StringFormat("MTC_slave_%d_%d.txt", AccountNumber(), InpMagic);
   LoadState();
   RescueLinksFromComments();
   SaveState();
   EventSetMillisecondTimer(MathMax(50, InpPollMs));
   Print("CopySlave: started, signal file Common\\Files\\", InpSignalFile, ", magic ", InpMagic, ", state file ", g_stateFile);
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveState();
   Comment("");
}
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_busy) return;
   g_busy = true;
   Process();
   if(g_dirty) SaveState();
   ShowStatus();
   g_busy = false;
}
//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
int FindMaster(long t)    { for(int i = 0; i < ArraySize(g_master); i++)   if(g_master[i].ticket == t)   return(i); return(-1); }
int FindState(long t)     { for(int i = 0; i < ArraySize(g_state); i++)    if(g_state[i].master == t)    return(i); return(-1); }
int FindAttempt(long t)   { for(int i = 0; i < ArraySize(g_attempts); i++) if(g_attempts[i].master == t) return(i); return(-1); }
int FindLinkBySlave(int s){ for(int i = 0; i < ArraySize(g_links); i++)    if(g_links[i].slave == s)     return(i); return(-1); }
int CountLinks(long m)    { int n = 0; for(int i = 0; i < ArraySize(g_links); i++) if(g_links[i].master == m) n++; return(n); }

void AddLink(long master, int slave)
{
   int n = ArraySize(g_links);
   ArrayResize(g_links, n + 1);
   g_links[n].master     = master;
   g_links[n].slave      = slave;
   g_links[n].retryAfter = 0;
   g_dirty = true;
}
void RemoveLink(int idx)
{
   int n = ArraySize(g_links);
   for(int i = idx; i < n - 1; i++) g_links[i] = g_links[i + 1];
   ArrayResize(g_links, n - 1);
   g_dirty = true;
}
void AddState(const MasterPos &mp)
{
   int n = ArraySize(g_state);
   ArrayResize(g_state, n + 1);
   g_state[n].master   = mp.ticket;
   g_state[n].volume   = mp.volume;
   g_state[n].symbol   = mp.symbol;
   g_state[n].type     = mp.type;
   g_state[n].opentime = mp.opentime;
   g_state[n].price    = mp.price;
   g_dirty = true;
}
void RemoveState(int idx)
{
   int n = ArraySize(g_state);
   for(int i = idx; i < n - 1; i++) g_state[i] = g_state[i + 1];
   ArrayResize(g_state, n - 1);
   g_dirty = true;
}
bool AttemptsExhausted(long master)
{
   int i = FindAttempt(master);
   return(i >= 0 && g_attempts[i].count >= InpMaxOpenAttempts);
}
void BumpAttempt(long master)
{
   int i = FindAttempt(master);
   if(i < 0)
   {
      i = ArraySize(g_attempts);
      ArrayResize(g_attempts, i + 1);
      g_attempts[i].master = master;
      g_attempts[i].count  = 0;
   }
   g_attempts[i].count++;
   if(g_attempts[i].count >= InpMaxOpenAttempts)
      Print("CopySlave: giving up on master ticket ", master, " after ", g_attempts[i].count, " failed attempts");
}
void ClearAttempt(long master)
{
   int i = FindAttempt(master);
   if(i < 0) return;
   int n = ArraySize(g_attempts);
   for(int k = i; k < n - 1; k++) g_attempts[k] = g_attempts[k + 1];
   ArrayResize(g_attempts, n - 1);
}
//--- select an open order of ours by ticket
bool SlaveOpen(int ticket)
{
   if(ticket <= 0) return(false);
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return(false);
   return(OrderCloseTime() == 0);
}
//+------------------------------------------------------------------+
//| Persistence (local Files folder)                                 |
//+------------------------------------------------------------------+
void SaveState()
{
   int h = FileOpen(g_stateFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) { Print("CopySlave: cannot write state file ", g_stateFile, " error ", GetLastError()); return; }
   for(int i = 0; i < ArraySize(g_links); i++)
      FileWrite(h, StringFormat("LINK|%I64d|%d", g_links[i].master, g_links[i].slave));
   for(int i = 0; i < ArraySize(g_state); i++)
      FileWrite(h, StringFormat("STATE|%I64d|%s|%s|%d|%I64d|%s", g_state[i].master, DoubleToString(g_state[i].volume, 8),
                                g_state[i].symbol, g_state[i].type, (long)g_state[i].opentime, DoubleToString(g_state[i].price, 8)));
   FileClose(h);
   g_dirty = false;
}
void LoadState()
{
   ArrayResize(g_links, 0);
   ArrayResize(g_state, 0);
   int h = FileOpen(g_stateFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      string p[];
      int n = StringSplit(line, '|', p);
      if(n >= 3 && p[0] == "LINK")
      {
         long m = StringToInteger(p[1]);
         int  s = (int)StringToInteger(p[2]);
         if(SlaveOpen(s) && FindLinkBySlave(s) < 0)
            AddLink(m, s);
         else
            Print("CopySlave: dropping stale link master ", m, " -> slave ", s, " (order no longer open)");
      }
      else if(n >= 7 && p[0] == "STATE")
      {
         MasterPos mp;
         mp.ticket   = StringToInteger(p[1]);
         mp.volume   = StringToDouble(p[2]);
         mp.symbol   = p[3];
         mp.type     = (int)StringToInteger(p[4]);
         mp.opentime = (datetime)StringToInteger(p[5]);
         mp.price    = StringToDouble(p[6]);
         mp.sl = 0; mp.tp = 0;
         if(FindState(mp.ticket) < 0) AddState(mp);
      }
   }
   FileClose(h);
   Print("CopySlave: loaded ", ArraySize(g_links), " links and ", ArraySize(g_state), " master states from ", g_stateFile);
}
//+------------------------------------------------------------------+
void RescueLinksFromComments()
{
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != InpMagic) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      int t = OrderTicket();
      if(FindLinkBySlave(t) >= 0) continue;
      string c = OrderComment();
      if(StringFind(c, "MC") != 0) continue;
      long m = StringToInteger(StringSubstr(c, 2));
      if(m == 0) continue;
      AddLink(m, t);
      Print("CopySlave: recovered link master ", m, " -> slave #", t, " from order comment");
   }
}
//+------------------------------------------------------------------+
//| Signal transport: local file or HTTP relay                       |
//+------------------------------------------------------------------+
bool FetchFromFile(string &text)
{
   int h = FileOpen(InpSignalFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) { g_status = "signal file not readable: Common\\Files\\" + InpSignalFile; return(false); }
   text = "";
   while(!FileIsEnding(h))
      text += FileReadString(h) + "\n";
   FileClose(h);
   g_relayAge = -1;
   return(true);
}
//--- The relay URL must be listed in Tools > Options > Expert Advisors > "Allow WebRequest for listed URL".
bool FetchFromUrl(string &text)
{
   char   data[];
   char   result[];
   string resultHeaders;
   string headers = "";
   if(InpApiKey != "") headers = "X-Api-Key: " + InpApiKey + "\r\n";

   ResetLastError();
   int code = WebRequest("GET", InpSignalUrl, headers, InpHttpTimeoutMs, data, result, resultHeaders);
   if(code == -1)
   {
      int err = GetLastError();
      g_status = "WebRequest error " + (string)err + (err == 4014 ? " - add the relay URL in Tools > Options > Expert Advisors" : "");
      return(false);
   }
   if(code == 404) { g_status = "relay has no signal yet - is CopyMaster running and posting to the same URL?"; return(false); }
   if(code != 200) { g_status = "relay HTTP " + (string)code + " " + CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8); return(false); }

   text = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   // The relay reports how long ago it received the signal (its own clock), which
   // makes the staleness check independent of clock differences between machines.
   g_relayAge = -1;
   int pos = StringFind(resultHeaders, "X-Age-Seconds:");
   if(pos >= 0)
   {
      string rest = StringSubstr(resultHeaders, pos + 14);
      int eol = StringFind(rest, "\n");
      if(eol >= 0) rest = StringSubstr(rest, 0, eol);
      g_relayAge = (long)MathRound(StringToDouble(Trim(rest)));
   }
   return(true);
}
//+------------------------------------------------------------------+
bool ReadSignal()
{
   string text;
   bool ok = (InpSignalUrl != "" ? FetchFromUrl(text) : FetchFromFile(text));
   if(!ok) return(false);

   MasterPos tmp[];
   bool haveHdr = false, haveEnd = false;
   string lines[];
   int nl = StringSplit(text, '\n', lines);
   for(int li = 0; li < nl; li++)
   {
      string line = lines[li];
      StringTrimRight(line);
      string p[];
      int n = StringSplit(line, '|', p);
      if(n < 1) continue;
      if(p[0] == "HDR" && n >= 9)
      {
         g_masterLogin      = StringToInteger(p[2]);
         g_masterCurrency   = p[3];
         g_masterBalance    = StringToDouble(p[4]);
         g_masterEquity     = StringToDouble(p[5]);
         g_masterServerTime = (datetime)StringToInteger(p[6]);
         g_masterGmt        = (datetime)StringToInteger(p[7]);
         g_masterPlatform   = p[8];
         haveHdr = true;
      }
      else if(p[0] == "POS" && n >= 9)
      {
         int k = ArraySize(tmp);
         ArrayResize(tmp, k + 1);
         tmp[k].ticket   = StringToInteger(p[1]);
         tmp[k].symbol   = p[2];
         tmp[k].type     = (int)StringToInteger(p[3]);
         tmp[k].volume   = StringToDouble(p[4]);
         tmp[k].price    = StringToDouble(p[5]);
         tmp[k].sl       = StringToDouble(p[6]);
         tmp[k].tp       = StringToDouble(p[7]);
         tmp[k].opentime = (datetime)StringToInteger(p[8]);
      }
      else if(p[0] == "END")
         haveEnd = true;
   }
   if(!haveHdr || !haveEnd) { g_status = "signal is incomplete (no HDR/END) - retrying"; return(false); }

   ArrayResize(g_master, ArraySize(tmp));
   for(int i = 0; i < ArraySize(tmp); i++) g_master[i] = tmp[i];
   return(true);
}
//+------------------------------------------------------------------+
//| Symbol mapping                                                   |
//+------------------------------------------------------------------+
string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return(s); }

string MapLookup(string base)
{
   if(InpSymbolMap == "") return("");
   string pairs[];
   int n = StringSplit(InpSymbolMap, ';', pairs);
   for(int i = 0; i < n; i++)
   {
      string kv[];
      if(StringSplit(pairs[i], '=', kv) == 2 && Trim(kv[0]) == base)
         return(Trim(kv[1]));
   }
   return("");
}
string StripMaster(string sym)
{
   string base = sym;
   if(InpMasterPrefix != "" && StringFind(base, InpMasterPrefix) == 0)
      base = StringSubstr(base, StringLen(InpMasterPrefix));
   if(InpMasterSuffix != "")
   {
      int L = StringLen(base), S = StringLen(InpMasterSuffix);
      if(L > S && StringSubstr(base, L - S) == InpMasterSuffix)
         base = StringSubstr(base, 0, L - S);
   }
   return(base);
}
bool IsAllowedSymbol(string masterSym)
{
   if(InpAllowedSymbols == "") return(true);
   string base = StripMaster(masterSym);
   string list[];
   int n = StringSplit(InpAllowedSymbols, ',', list);
   for(int i = 0; i < n; i++)
   {
      string s = Trim(list[i]);
      if(s == "") continue;
      if(s == masterSym || s == base) return(true);
   }
   return(false);
}
bool SymbolUsable(string s)
{
   if(s == "") return(false);
   if(!SymbolSelect(s, true)) return(false);
   return(MarketInfo(s, MODE_TRADEALLOWED) != 0);
}
string ResolveSymbol(string masterSym)
{
   for(int i = 0; i < ArraySize(g_symFrom); i++)
      if(g_symFrom[i] == masterSym) return(g_symTo[i]);

   string base   = StripMaster(masterSym);
   string mapped = MapLookup(base);
   if(mapped != "") base = mapped;

   string result = "";
   string cand[4];
   cand[0] = InpSlavePrefix + base + InpSlaveSuffix;
   cand[1] = base;
   cand[2] = masterSym;
   cand[3] = mapped;
   for(int i = 0; i < 4 && result == ""; i++)
      if(SymbolUsable(cand[i])) result = cand[i];

   if(result == "")   // last resort: any symbol that starts with the base name (broker suffix)
   {
      int total = SymbolsTotal(false);
      for(int i = 0; i < total; i++)
      {
         string s = SymbolName(i, false);
         if(StringFind(s, base) == 0 && SymbolUsable(s)) { result = s; break; }
      }
   }

   int n = ArraySize(g_symFrom);
   ArrayResize(g_symFrom, n + 1);
   ArrayResize(g_symTo, n + 1);
   g_symFrom[n] = masterSym;
   g_symTo[n]   = result;
   if(result == "") Print("CopySlave: no tradable symbol found for master symbol ", masterSym, " - use the symbol mapping inputs");
   else if(result != masterSym) Print("CopySlave: master symbol ", masterSym, " mapped to ", result);
   return(result);
}
//+------------------------------------------------------------------+
//| Lot sizing                                                       |
//+------------------------------------------------------------------+
double FloorToStep(string sym, double lots)
{
   double step = MarketInfo(sym, MODE_LOTSTEP);
   if(step > 0) lots = MathFloor(lots / step + 0.0000001) * step;
   return(NormalizeDouble(lots, 8));
}
double NormalizeLots(string sym, double lots)
{
   double minv = MarketInfo(sym, MODE_MINLOT);
   double maxv = MarketInfo(sym, MODE_MAXLOT);
   if(InpMaxLots > 0) maxv = MathMin(maxv, InpMaxLots);
   lots = FloorToStep(sym, lots);
   if(lots < minv) lots = minv;
   if(lots > maxv) lots = maxv;
   return(NormalizeDouble(lots, 8));
}
double CalcLots(string sym, double masterVol)
{
   double lots = masterVol;
   switch(InpLotMode)
   {
      case LOT_FIXED:      lots = InpFixedLots; break;
      case LOT_MULTIPLIER: lots = masterVol * InpLotMultiplier; break;
      case LOT_BALANCE:
         if(g_masterBalance > 0) lots = masterVol * (AccountBalance() / g_masterBalance) * InpLotMultiplier;
         else lots = masterVol * InpLotMultiplier;
         break;
      case LOT_EQUITY:
         if(g_masterEquity > 0) lots = masterVol * (AccountEquity() / g_masterEquity) * InpLotMultiplier;
         else lots = masterVol * InpLotMultiplier;
         break;
   }
   return(NormalizeLots(sym, lots));
}
//+------------------------------------------------------------------+
//| Trading helpers                                                  |
//+------------------------------------------------------------------+
bool StopValid(int otype, bool isSL, double lvl, double bid, double ask)
{
   if(lvl <= 0) return(true);
   if(otype == OP_BUY) return(isSL ? (lvl < bid) : (lvl > bid));
   return(isSL ? (lvl > ask) : (lvl < ask));
}
bool TradingAllowed()
{
   if(!IsConnected())        { g_status = "Terminal not connected"; return(false); }
   if(!IsExpertEnabled())    { g_status = "AutoTrading is disabled in the terminal"; return(false); }
   if(!IsTradeAllowed())     { g_status = "Trading not allowed (EA properties / account / trade context busy)"; return(false); }
   return(true);
}
//+------------------------------------------------------------------+
//| After a partial close MT4 gives the remaining part a NEW ticket. |
//| Find it: same symbol/type/magic/open time, not linked yet.       |
//+------------------------------------------------------------------+
int FindRemainder(string sym, int otype, datetime opentime, int oldTicket)
{
   for(int attempt = 0; attempt < 20; attempt++)
   {
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderTicket() == oldTicket) continue;
         if(OrderMagicNumber() != InpMagic) continue;
         if(OrderSymbol() != sym) continue;
         if(OrderType() != otype) continue;
         if(OrderOpenTime() != opentime) continue;
         if(FindLinkBySlave(OrderTicket()) >= 0) continue;
         return(OrderTicket());
      }
      Sleep(50);
   }
   return(0);
}
//+------------------------------------------------------------------+
//| Open a copy of a master position for the given master volume.    |
//+------------------------------------------------------------------+
bool OpenCopy(const MasterPos &mp, double masterVol)
{
   string sym = ResolveSymbol(mp.symbol);
   if(sym == "") return(false);

   int type = mp.type;
   if(InpReverse) type = 1 - type;
   int cmd = (type == 0 ? OP_BUY : OP_SELL);

   double lots = CalcLots(sym, masterVol);
   if(lots <= 0) { Print("CopySlave: computed lots <= 0 for ", sym); return(false); }

   if(InpMaxSpreadPoints > 0)
   {
      int spread = (int)MarketInfo(sym, MODE_SPREAD);
      if(spread > InpMaxSpreadPoints)
      {
         Print("CopySlave: spread ", spread, " > ", InpMaxSpreadPoints, " points on ", sym, ", not opening master ", mp.ticket, " yet");
         return(false);
      }
   }

   RefreshRates();
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);
   double bid    = MarketInfo(sym, MODE_BID);
   double ask    = MarketInfo(sym, MODE_ASK);
   double price  = NormalizeDouble(cmd == OP_BUY ? ask : bid, digits);
   string cmt    = "MC" + (string)mp.ticket;

   // Open without SL/TP (ECN safe), then set them with OrderModify.
   int ticket = OrderSend(sym, cmd, lots, price, InpSlippagePoints, 0, 0, cmt, InpMagic, 0, clrNONE);
   if(ticket < 0)
   {
      int err = GetLastError();
      Print("CopySlave: open FAILED master ", mp.ticket, " ", sym, " ", (cmd == OP_BUY ? "BUY" : "SELL"), " ", DoubleToString(lots, 2), " error ", err);
      return(false);
   }
   AddLink(mp.ticket, ticket);
   Print("CopySlave: opened ", sym, " ", (cmd == OP_BUY ? "BUY" : "SELL"), " ", DoubleToString(lots, 2), " #", ticket, " <- master ", mp.ticket, " (", mp.symbol, " ", DoubleToString(masterVol, 2), " lots)");

   if(InpSLTPMode == SLTP_PRICE && (mp.sl > 0 || mp.tp > 0))
      SyncStops(mp);   // best effort now; retried every cycle anyway
   return(true);
}
//+------------------------------------------------------------------+
bool CloseSlave(int slave, string why)
{
   if(!SlaveOpen(slave)) return(true);
   string sym = OrderSymbol();
   RefreshRates();
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);
   double price  = NormalizeDouble(OrderType() == OP_BUY ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK), digits);
   if(!OrderClose(slave, OrderLots(), price, InpSlippagePoints, clrNONE))
   {
      Print("CopySlave: close FAILED #", slave, " error ", GetLastError());
      return(false);
   }
   Print("CopySlave: closed #", slave, " (", why, ")");
   return(true);
}
//+------------------------------------------------------------------+
//| Reduce a copy to (ratio x current lots). Returns new ticket or   |
//| the same ticket; 0 if the order is gone / closed entirely.       |
//+------------------------------------------------------------------+
int ReduceSlave(int slave, double ratio)
{
   if(!SlaveOpen(slave)) return(0);
   string   sym      = OrderSymbol();
   int      otype    = OrderType();
   datetime opentime = OrderOpenTime();
   double   vol      = OrderLots();
   double   minv     = MarketInfo(sym, MODE_MINLOT);
   double   step     = MarketInfo(sym, MODE_LOTSTEP);
   double   target   = FloorToStep(sym, vol * ratio);
   double   closeV   = NormalizeDouble(vol - target, 8);

   if(target < minv - VOL_EPS) { CloseSlave(slave, "master reduced below minimum lot"); return(0); }
   if(closeV < step / 2) return(slave);

   RefreshRates();
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);
   double price  = NormalizeDouble(otype == OP_BUY ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK), digits);
   if(!OrderClose(slave, closeV, price, InpSlippagePoints, clrNONE))
   {
      Print("CopySlave: partial close FAILED #", slave, " ", DoubleToString(closeV, 2), " error ", GetLastError());
      return(slave);
   }
   Print("CopySlave: partially closed #", slave, " by ", DoubleToString(closeV, 2), " lots (master reduced)");

   int rest = FindRemainder(sym, otype, opentime, slave);
   if(rest == 0)
      Print("CopySlave: could not find the remaining part of #", slave, " after partial close - it will not be managed automatically");
   return(rest);
}
//+------------------------------------------------------------------+
//| Keep SL/TP of all copies of a master position in sync.           |
//+------------------------------------------------------------------+
void SyncStops(const MasterPos &mp)
{
   for(int i = 0; i < ArraySize(g_links); i++)
   {
      if(g_links[i].master != mp.ticket) continue;
      if(g_links[i].retryAfter > TimeLocal()) continue;
      if(!SlaveOpen(g_links[i].slave)) continue;

      string sym    = OrderSymbol();
      int    otype  = OrderType();
      int    digits = (int)MarketInfo(sym, MODE_DIGITS);
      double point  = MarketInfo(sym, MODE_POINT);
      double curSL  = OrderStopLoss();
      double curTP  = OrderTakeProfit();
      RefreshRates();
      double bid    = MarketInfo(sym, MODE_BID);
      double ask    = MarketInfo(sym, MODE_ASK);

      double wantSL = mp.sl, wantTP = mp.tp;
      if(InpReverse) { double t = wantSL; wantSL = wantTP; wantTP = t; }
      if(!StopValid(otype, true,  wantSL, bid, ask)) wantSL = curSL;
      if(!StopValid(otype, false, wantTP, bid, ask)) wantTP = curTP;
      wantSL = NormalizeDouble(wantSL, digits);
      wantTP = NormalizeDouble(wantTP, digits);

      if(MathAbs(wantSL - curSL) < point / 2 && MathAbs(wantTP - curTP) < point / 2) continue;

      if(!OrderModify(g_links[i].slave, OrderOpenPrice(), wantSL, wantTP, 0, clrNONE))
      {
         int err = GetLastError();
         if(err == 1) continue;   // ERR_NO_RESULT: nothing changed
         Print("CopySlave: modify FAILED #", g_links[i].slave, " SL ", DoubleToString(wantSL, digits), " TP ", DoubleToString(wantTP, digits), " error ", err, " - retry in 10 s");
         g_links[i].retryAfter = TimeLocal() + 10;
      }
      else
         Print("CopySlave: #", g_links[i].slave, " SL/TP -> ", DoubleToString(wantSL, digits), " / ", DoubleToString(wantTP, digits));
   }
}
//+------------------------------------------------------------------+
int FindSuccessor(const MState &st)
{
   for(int i = 0; i < ArraySize(g_master); i++)
   {
      if(FindState(g_master[i].ticket) >= 0) continue;
      if(g_master[i].symbol != st.symbol) continue;
      if(g_master[i].type != st.type) continue;
      if(g_master[i].opentime != st.opentime) continue;
      if(MathAbs(g_master[i].price - st.price) > 0.0000001) continue;
      if(g_master[i].volume > st.volume + VOL_EPS) continue;
      return(i);
   }
   return(-1);
}
//+------------------------------------------------------------------+
//| Main cycle                                                       |
//+------------------------------------------------------------------+
void Process()
{
   //--- 1. read and validate the signal
   if(!ReadSignal()) return;   // g_status already explains why
   if(InpMasterAccount != 0 && g_masterLogin != InpMasterAccount)
   {
      g_status = StringFormat("signal is from account %I64d, expected %I64d - ignoring", g_masterLogin, InpMasterAccount);
      return;
   }
   long age = SignalAge();
   if(age > InpMaxSignalAgeSec)
   {
      g_status = StringFormat("signal is %d s old - master offline? (no action taken)", (int)age);
      return;
   }
   if(!TradingAllowed()) return;

   //--- 2. forget links whose copy is gone
   for(int i = ArraySize(g_links) - 1; i >= 0; i--)
      if(!SlaveOpen(g_links[i].slave))
      {
         Print("CopySlave: copy #", g_links[i].slave, " of master ", g_links[i].master, " is no longer open - unlinking");
         RemoveLink(i);
      }

   //--- 3. master positions that disappeared
   for(int i = ArraySize(g_state) - 1; i >= 0; i--)
   {
      long m = g_state[i].master;
      if(FindMaster(m) >= 0) continue;

      int succ = FindSuccessor(g_state[i]);
      if(succ >= 0)
      {
         long nm = g_master[succ].ticket;
         Print("CopySlave: master ticket ", m, " became ", nm, " (partial close on master)");
         for(int k = 0; k < ArraySize(g_links); k++)
            if(g_links[k].master == m) g_links[k].master = nm;
         g_state[i].master = nm;
         ClearAttempt(m);
         g_dirty = true;
         continue;
      }

      for(int k = ArraySize(g_links) - 1; k >= 0; k--)
      {
         if(g_links[k].master != m) continue;
         if(InpCloseWithMaster)
         {
            if(!CloseSlave(g_links[k].slave, "master " + (string)m + " closed")) continue;
         }
         else
            Print("CopySlave: master ", m, " closed, copy #", g_links[k].slave, " left open (InpCloseWithMaster=false)");
         RemoveLink(k);
      }
      if(CountLinks(m) == 0)
      {
         RemoveState(i);
         ClearAttempt(m);
      }
   }

   //--- 4. new master positions and volume changes
   for(int i = 0; i < ArraySize(g_master); i++)
   {
      MasterPos mp = g_master[i];
      int si = FindState(mp.ticket);
      int nLinks = CountLinks(mp.ticket);

      if(si < 0)
      {
         if(nLinks > 0) { AddState(mp); continue; }
         if(!IsAllowedSymbol(mp.symbol)) { AddState(mp); continue; }
         long tradeAge = (long)g_masterServerTime - (long)mp.opentime;
         if(InpMaxTradeAgeSec > 0 && tradeAge > InpMaxTradeAgeSec)
         {
            Print("CopySlave: master ", mp.ticket, " ", mp.symbol, " is ", tradeAge, " s old - not copying (InpMaxTradeAgeSec)");
            AddState(mp);
            continue;
         }
         if(AttemptsExhausted(mp.ticket)) { AddState(mp); continue; }
         if(OpenCopy(mp, mp.volume)) { AddState(mp); ClearAttempt(mp.ticket); }
         else BumpAttempt(mp.ticket);
         continue;
      }

      double prev = g_state[si].volume;
      if(mp.volume < prev - VOL_EPS)
      {
         double ratio = mp.volume / prev;
         for(int k = ArraySize(g_links) - 1; k >= 0; k--)
         {
            if(g_links[k].master != mp.ticket) continue;
            int rest = ReduceSlave(g_links[k].slave, ratio);
            if(rest == 0) RemoveLink(k);
            else if(rest != g_links[k].slave) { g_links[k].slave = rest; g_dirty = true; }
         }
         g_state[si].volume = mp.volume;
         g_dirty = true;
      }
      else if(mp.volume > prev + VOL_EPS)
      {
         double delta = mp.volume - prev;
         if(!IsAllowedSymbol(mp.symbol) || AttemptsExhausted(mp.ticket))
         {
            g_state[si].volume = mp.volume; g_dirty = true;
         }
         else if(OpenCopy(mp, delta))
         {
            g_state[si].volume = mp.volume; g_dirty = true; ClearAttempt(mp.ticket);
         }
         else BumpAttempt(mp.ticket);
      }

      if(InpSLTPMode == SLTP_PRICE) SyncStops(mp);
   }

   g_status = "OK";
}
//+------------------------------------------------------------------+
long SignalAge()
{
   if(g_relayAge >= 0) return(g_relayAge);
   return((long)TimeGMT() - (long)g_masterGmt);
}
//+------------------------------------------------------------------+
void ShowStatus()
{
   long age = SignalAge();
   Comment(StringFormat("MetaTraderCopy SLAVE (MT4)   magic %d\nMaster: %I64d (%s)  balance %.2f %s  equity %.2f\nSignal: %s   age %d s\nMaster positions: %d   linked copies: %d\nStatus: %s",
                        InpMagic, g_masterLogin, g_masterPlatform, g_masterBalance, g_masterCurrency, g_masterEquity,
                        (InpSignalUrl != "" ? InpSignalUrl : "Common\\Files\\" + InpSignalFile), (int)age, ArraySize(g_master), ArraySize(g_links), g_status));
}
//+------------------------------------------------------------------+
