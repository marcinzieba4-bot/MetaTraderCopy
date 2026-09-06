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
//| the trades.                                                      |
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

input string InpSignalFile = "MTC_master.txt"; // Signal file name (written to Common\Files)
input int    InpWriteMs    = 250;              // Publish interval, milliseconds

int    g_published = 0;
string g_lastError = "";

//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(MathMax(50, InpWriteMs));
   PublishSignal();
   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
//+------------------------------------------------------------------+
void OnTimer() { PublishSignal(); }
void OnTick()  { PublishSignal(); }
//+------------------------------------------------------------------+
string Sanitize(string s)
{
   StringReplace(s, "|", "/");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return(s);
}
//+------------------------------------------------------------------+
//| Write all open market orders to a temp file, then atomically     |
//| swap it in place of the signal file.                             |
//+------------------------------------------------------------------+
void PublishSignal()
{
   string tmp = InpSignalFile + ".tmp";
   int h = FileOpen(tmp, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      g_lastError = "cannot open " + tmp + " (error " + (string)GetLastError() + ")";
      Print("CopyMaster: ", g_lastError);
      return;
   }

   FileWrite(h, StringFormat("HDR|%d|%d|%s|%s|%s|%I64d|%I64d|MT4",
                             MTC_FORMAT_VERSION,
                             AccountNumber(),
                             AccountCurrency(),
                             DoubleToString(AccountBalance(), 2),
                             DoubleToString(AccountEquity(), 2),
                             (long)TimeCurrent(),
                             (long)TimeGMT()));

   int count = 0;
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

      FileWrite(h, StringFormat("POS|%d|%s|%d|%s|%s|%s|%s|%I64d|%d|%s",
                                OrderTicket(),
                                sym,
                                (otype == OP_BUY ? 0 : 1),
                                DoubleToString(OrderLots(), 8),
                                DoubleToString(OrderOpenPrice(), digits),
                                DoubleToString(OrderStopLoss(), digits),
                                DoubleToString(OrderTakeProfit(), digits),
                                (long)OrderOpenTime(),
                                OrderMagicNumber(),
                                Sanitize(OrderComment())));
      count++;
   }
   FileWrite(h, "END");
   FileClose(h);

   if(!FileMove(tmp, FILE_COMMON, InpSignalFile, FILE_COMMON | FILE_REWRITE))
   {
      g_lastError = "FileMove failed (error " + (string)GetLastError() + ")";
      Print("CopyMaster: ", g_lastError);
      return;
   }

   g_lastError = "";
   g_published++;

   Comment(StringFormat("MetaTraderCopy MASTER (MT4)\nAccount: %d   Orders published: %d\nSignal file: Common\\Files\\%s\nLast publish: %s   Writes: %d",
                        AccountNumber(), count, InpSignalFile,
                        TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS), g_published));
}
//+------------------------------------------------------------------+
