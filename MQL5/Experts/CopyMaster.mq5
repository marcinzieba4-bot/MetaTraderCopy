//+------------------------------------------------------------------+
//|                                                   CopyMaster.mq5 |
//|                                                   MetaTraderCopy |
//+------------------------------------------------------------------+
//| MASTER side of the MetaTraderCopy trade copier (MetaTrader 5).   |
//|                                                                  |
//| Attach this EA to ONE chart of the account whose trades you want |
//| to copy. It publishes every open market position of the account  |
//| to a text file in the terminal "Common\Files" folder several     |
//| times per second. CopySlave EAs running in other terminals on    |
//| the same machine (or VPS) read that file and mirror the trades.  |
//|                                                                  |
//| Signal file format (one record per line, pipe separated):        |
//|   HDR|version|login|currency|balance|equity|serverTime|gmtTime|MT5 |
//|   POS|ticket|symbol|type|volume|open|sl|tp|openTime|magic|comment  |
//|   END                                                            |
//| type: 0 = buy, 1 = sell. Times are unix seconds.                 |
//+------------------------------------------------------------------+
#property copyright   "MetaTraderCopy"
#property link        "https://github.com/marcinzieba4-bot/MetaTraderCopy"
#property version     "1.00"
#property description "Master side of the MetaTraderCopy trade copier."
#property description "Publishes open positions to Common\\Files so CopySlave EAs can mirror them."

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
void OnTrade() { PublishSignal(); }
//+------------------------------------------------------------------+
//| Remove characters that would break the line based format.        |
//+------------------------------------------------------------------+
string Sanitize(string s)
{
   StringReplace(s, "|", "/");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return(s);
}
//+------------------------------------------------------------------+
//| Write all open positions to a temp file, then atomically swap it |
//| in place of the signal file so readers never see a half file.    |
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

   FileWrite(h, StringFormat("HDR|%d|%I64d|%s|%s|%s|%I64d|%I64d|MT5",
                             MTC_FORMAT_VERSION,
                             AccountInfoInteger(ACCOUNT_LOGIN),
                             AccountInfoString(ACCOUNT_CURRENCY),
                             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
                             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
                             (long)TimeCurrent(),
                             (long)TimeGMT()));

   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      long ptype = PositionGetInteger(POSITION_TYPE);
      if(ptype != POSITION_TYPE_BUY && ptype != POSITION_TYPE_SELL)
         continue;

      string sym    = PositionGetString(POSITION_SYMBOL);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

      FileWrite(h, StringFormat("POS|%I64u|%s|%d|%s|%s|%s|%s|%I64d|%I64d|%s",
                                ticket,
                                sym,
                                (ptype == POSITION_TYPE_BUY ? 0 : 1),
                                DoubleToString(PositionGetDouble(POSITION_VOLUME), 8),
                                DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digits),
                                DoubleToString(PositionGetDouble(POSITION_SL), digits),
                                DoubleToString(PositionGetDouble(POSITION_TP), digits),
                                (long)PositionGetInteger(POSITION_TIME),
                                (long)PositionGetInteger(POSITION_MAGIC),
                                Sanitize(PositionGetString(POSITION_COMMENT))));
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

   Comment(StringFormat("MetaTraderCopy MASTER (MT5)\nAccount: %I64d   Positions published: %d\nSignal file: Common\\Files\\%s\nLast publish: %s   Writes: %d%s",
                        AccountInfoInteger(ACCOUNT_LOGIN), count, InpSignalFile,
                        TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS), g_published,
                        (g_lastError == "" ? "" : "\nERROR: " + g_lastError)));
}
//+------------------------------------------------------------------+
