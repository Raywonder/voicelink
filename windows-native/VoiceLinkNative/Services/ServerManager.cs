using System;
using System.Collections.ObjectModel;

namespace VoiceLinkNative.Services
{
    public class ServerManager
    {
        public static void OnReconnecting()
        {
            Console.WriteLine("Reconnecting to server...");
        }

        public static void OnConnected()
        {
            Console.WriteLine("Connected to server");
        }
    }
}