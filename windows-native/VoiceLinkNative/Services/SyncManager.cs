using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace VoiceLinkNative.Services;

public class SyncManager : INotifyPropertyChanged
{
    public static SyncManager Instance { get; private set; } = null!;

    // Events for UI updates
    public event EventHandler<MembershipUpdate>? MembershipUpdated;
    public event EventHandler<TrustUpdate>? TrustUpdated;
    public event EventHandler<WalletUpdate>? WalletUpdated;
    public event EventHandler<ComplaintReceived>? ComplaintReceived;
    public event EventHandler<LevelUpgrade>? LevelUpgraded;

    private DateTime _lastSyncTime;
    public DateTime LastSyncTime
    {
        get => _lastSyncTime;
        private set { _lastSyncTime = value; OnPropertyChanged(); }
    }

    public SyncManager()
    {
        Instance = this;

        // Subscribe to server push events
        ServerManager.Instance.SyncPushReceived += HandleServerPush;
    }

    private void HandleServerPush(object? sender, SyncPushData e)
    {
        LastSyncTime = DateTime.Now;

        switch (e.Type)
        {
            case "membership_update":
                var membership = ParseMembershipUpdate(e.Data);
                if (membership != null)
                    MembershipUpdated?.Invoke(this, membership);
                break;

            case "trust_update":
                var trust = ParseTrustUpdate(e.Data);
                if (trust != null)
                    TrustUpdated?.Invoke(this, trust);
                break;

            case "wallet_update":
                var wallet = ParseWalletUpdate(e.Data);
                if (wallet != null)
                    WalletUpdated?.Invoke(this, wallet);
                break;

            case "complaint":
                var complaint = ParseComplaint(e.Data);
                if (complaint != null)
                    ComplaintReceived?.Invoke(this, complaint);
                break;

            case "level_upgrade":
                var levelUp = ParseLevelUpgrade(e.Data);
                if (levelUp != null)
                    LevelUpgraded?.Invoke(this, levelUp);
                break;
        }
    }

    private MembershipUpdate? ParseMembershipUpdate(Dictionary<string, object>? data)
    {
        if (data == null) return null;

        return new MembershipUpdate
        {
            UserId = data.TryGetValue("userId", out var uid) ? uid?.ToString() ?? "" : "",
            NewLevel = data.TryGetValue("level", out var lvl) ? lvl?.ToString() ?? "" : "",
            ExpiresAt = data.TryGetValue("expiresAt", out var exp) && exp is DateTime dt ? dt : null
        };
    }

    private TrustUpdate? ParseTrustUpdate(Dictionary<string, object>? data)
    {
        if (data == null) return null;

        return new TrustUpdate
        {
            UserId = data.TryGetValue("userId", out var uid) ? uid?.ToString() ?? "" : "",
            NewScore = data.TryGetValue("score", out var score) ? Convert.ToDouble(score) : 0,
            Reason = data.TryGetValue("reason", out var reason) ? reason?.ToString() : null
        };
    }

    private WalletUpdate? ParseWalletUpdate(Dictionary<string, object>? data)
    {
        if (data == null) return null;

        return new WalletUpdate
        {
            UserId = data.TryGetValue("userId", out var uid) ? uid?.ToString() ?? "" : "",
            NewBalance = data.TryGetValue("balance", out var bal) ? Convert.ToDecimal(bal) : 0,
            Currency = data.TryGetValue("currency", out var cur) ? cur?.ToString() ?? "USD" : "USD"
        };
    }

    private ComplaintReceived? ParseComplaint(Dictionary<string, object>? data)
    {
        if (data == null) return null;

        return new ComplaintReceived
        {
            ComplaintId = data.TryGetValue("complaintId", out var cid) ? cid?.ToString() ?? "" : "",
            FromUserId = data.TryGetValue("from", out var from) ? from?.ToString() ?? "" : "",
            Reason = data.TryGetValue("reason", out var reason) ? reason?.ToString() ?? "" : ""
        };
    }

    private LevelUpgrade? ParseLevelUpgrade(Dictionary<string, object>? data)
    {
        if (data == null) return null;

        return new LevelUpgrade
        {
            UserId = data.TryGetValue("userId", out var uid) ? uid?.ToString() ?? "" : "",
            OldLevel = data.TryGetValue("oldLevel", out var old) ? old?.ToString() ?? "" : "",
            NewLevel = data.TryGetValue("newLevel", out var newLvl) ? newLvl?.ToString() ?? "" : "",
            Benefits = data.TryGetValue("benefits", out var ben) ? ben?.ToString() : null
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    protected virtual void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

// Sync Event Models
public class MembershipUpdate
{
    public string UserId { get; set; } = "";
    public string NewLevel { get; set; } = "";
    public DateTime? ExpiresAt { get; set; }
}

public class TrustUpdate
{
    public string UserId { get; set; } = "";
    public double NewScore { get; set; }
    public string? Reason { get; set; }
}

public class WalletUpdate
{
    public string UserId { get; set; } = "";
    public decimal NewBalance { get; set; }
    public string Currency { get; set; } = "USD";
}

public class ComplaintReceived
{
    public string ComplaintId { get; set; } = "";
    public string FromUserId { get; set; } = "";
    public string Reason { get; set; } = "";
}

public class LevelUpgrade
{
    public string UserId { get; set; } = "";
    public string OldLevel { get; set; } = "";
    public string NewLevel { get; set; } = "";
    public string? Benefits { get; set; }
}
