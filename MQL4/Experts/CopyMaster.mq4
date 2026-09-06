//+------------------------------------------------------------------+
//|                                                   CopyMaster.mq4 |
//|                                                   MetaTraderCopy |
//+------------------------------------------------------------------+
//| MASTER side of the MetaTraderCopy trade copier (MetaTrader 4).   |
//|                                                                  |
//| Attach this EA to ONE chart of the account whose trades you want |
//| to copy. It publishes every open market order (buy/sell) of the  |
//| account to a text file in the terminal "Common\Files" folder     |
//| several times per second. CopySlave EAs (MT4 or MT5) running in  |
//| other terminals on the same machine read that file and mirror    |
//| the trades. Optionally the same text is POSTed to a relay server |
//| (see relay/) so slaves on OTHER machines can fetch it.           |
//|                                                                  |
//| Signal file format (one record per line, pipe separated):        |
//|   HDR|version|login|currency|balance|equity|serverTime|gmtTime|MT4 |
//|   POS|ticket|symbol|type|volume|open|sl|tp|openTime|magic|comment  |
//|   END                                                            |
//| type: 0 = buy, 1 = sell. Times are unix seconds.                 |
//+------------------------------------------------------------------+
#property copyright   "MetaTraderCopy"
#property link        "https://github.com/marcinzieba4-bot/MetaTraderCopy"
#property version     "1.00"
#property description "Master side of the MetaTraderCopy trade copier."
#property description "Publishes open orders to Common\\Files so CopySlave EAs can mirror them."
#property strict

#define MTC_FORMAT_VERSION 1

//--- Local transport (slaves on this machine)
input string InpSignalFile    = "MTC_master.txt"; // Signal file name in Common\Files (empty = do not write)
input int    InpWriteMs       = 250;              // File publish interval, milliseconds
//--- Network transport (slaves on other machines)
input string InpSignalUrl     = "";               // Relay URL, e.g. https://relay.example.com/signal/mymaster (empty = off)
input string InpApiKey        = "";               // Relay API key
input int    InpPostMs        = 500;              // Relay publish interval, milliseconds
input int    InpHttpTimeoutMs = 2000;             // HTTP timeout, milliseconds

int    g_published  = 0;
int    g_posted     = 0;
int    g_count      = 0;
string g_lastError  = "";
string g_lastNetErr = "";
uint   g_lastPostTick = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(MathMax(50, InpWriteMs));
   if(InpSignalFile == "" && InpSignalUrl == "")
   {
      Print("CopyMaster: both InpSignalFile and InpSignalUrl are empty - nothing to publish to");
      return(INIT_PARAMETERS_INCORRECT);
   }
   PublishSignal(true);
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
//+------------------------------------------------------------------+
void OnTimer() { PublishSignal(false); }
void OnTick()  { PublishSignal(false); }
//+------------------------------------------------------------------+
string Sanitize(string s)
{
   StringReplace(s, "|", "/");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return(s);
}
//+------------------------------------------------------------------+
//| Build the signal text (see header comment for the format).       |
//+------------------------------------------------------------------+
string BuildSignal(int &count)
{
   string text = StringFormat("HDR|%d|%d|%s|%s|%s|%I64d|%I64d|MT4\r\n",
                              MTC_FORMAT_VERSION,
                              AccountNumber(),
                              AccountCurrency(),
                              DoubleToString(AccountBalance(), 2),
                              DoubleToString(AccountEquity(), 2),
                              (long)TimeCurrent(),
                              (long)TimeGMT());
   count = 0;
   int total = OrdersTotal();
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      int otype = OrderType();
      if(otype != OP_BUY && otype != OP_SELL)
         continue;

      string sym    = OrderSymbol();
      int    digits = (int)MarketInfo(sym, MODE_DIGITS);

      text += StringFormat("POS|%d|%s|%d|%s|%s|%s|%s|%I64d|%d|%s\r\n",
                           OrderTicket(),
                           sym,
                           (otype == OP_BUY ? 0 : 1),
                           DoubleToString(OrderLots(), 8),
                           DoubleToString(OrderOpenPrice(), digits),
                           DoubleToString(OrderStopLoss(), digits),
                           DoubleToString(OrderTakeProfit(), digits),
                           (long)OrderOpenTime(),
                           OrderMagicNumber(),
                           Sanitize(OrderComment()));
      count++;
   }
   text += "END\r\n";
   return(text);
}
//+------------------------------------------------------------------+
//| Write the text to a temp file, then atomically swap it in place  |
//| of the signal file so readers never see a half file.             |
//+------------------------------------------------------------------+
bool WriteSignalFile(const string text)
{
   string tmp = InpSignalFile + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      g_lastError = "cannot open " + tmp + " (error " + (string)GetLastError() + ")";
      Print("CopyMaster: ", g_lastError);
      return(false);
   }
   FileWriteString(h, text);
   FileClose(h);
   if(!FileMove(tmp, FILE_COMMON, InpSignalFile, FILE_COMMON | FILE_REWRITE))
   {
      g_lastError = "FileMove failed (error " + (string)GetLastError() + ")";
      Print("CopyMaster: ", g_lastError);
      return(false);
   }
   g_lastError = "";
   g_published++;
   return(true);
}
//+------------------------------------------------------------------+
//| POST the text to the relay so slaves on other machines get it.   |
//| The relay URL must be listed in Tools > Options > Expert         |
//| Advisors > "Allow WebRequest for listed URL".                    |
//+------------------------------------------------------------------+
bool PostSignal(const string text)
{
   char   data[];
   char   result[];
   string resultHeaders;
   int n = StringToCharArray(text, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0 && data[n - 1] == 0) ArrayResize(data, n - 1);   // drop the terminating zero

   string headers = "Content-Type: text/plain\r\n";
   if(InpApiKey != "") headers += "X-Api-Key: " + InpApiKey + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", InpSignalUrl, headers, InpHttpTimeoutMs, data, result, resultHeaders);
   if(code == -1)
   {
      int err = GetLastError();
      g_lastNetErr = "WebRequest error " + (string)err + (err == 4014 ? " - add the relay URL in Tools > Options > Expert Advisors" : "");
      Print("CopyMaster: ", g_lastNetErr);
      return(false);
   }
   if(code < 200 || code >= 300)
   {
      g_lastNetErr = "relay HTTP " + (string)code + " " + CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      Print("CopyMaster: ", g_lastNetErr);
      return(false);
   }
   g_lastNetErr = "";
   g_posted++;
   return(true);
}
//+------------------------------------------------------------------+
void PublishSignal(bool force)
{
   string text = BuildSignal(g_count);

   if(InpSignalFile != "")
      WriteSignalFile(text);

   if(InpSignalUrl != "")
   {
      uint now = GetTickCount();
      if(force || now - g_lastPostTick >= (uint)InpPostMs)
      {
         g_lastPostTick = now;
         PostSignal(text);
      }
   }

   string line = StringFormat("MetaTraderCopy MASTER (MT4)   account %d   orders published: %d", AccountNumber(), g_count);
   if(InpSignalFile != "") line += StringFormat("\nFile : Common\\Files\\%s   writes %d%s", InpSignalFile, g_published, (g_lastError == "" ? "" : "   ERROR: " + g_lastError));
   if(InpSignalUrl != "")  line += StringFormat("\nRelay: %s   posts %d%s", InpSignalUrl, g_posted, (g_lastNetErr == "" ? "" : "   ERROR: " + g_lastNetErr));
   line += "\nLast publish: " + TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS);
   Comment(line);
}
//+------------------------------------------------------------------+
