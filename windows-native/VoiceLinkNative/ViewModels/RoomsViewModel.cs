using System;
using System.Windows;

namespace VoiceLinkNative.ViewModels
{
    public class RoomsViewModel
    {
        public string RoomName { get; set; }
        public int UserCount { get; set; }

        public void CreateRoom()
        {
            RoomName = "New VoiceLink Room";
            UserCount = 0;
        }

        public void JoinRoom()
        {
            RoomName = "Joined Room";
            UserCount = 1;
        }
    }
}