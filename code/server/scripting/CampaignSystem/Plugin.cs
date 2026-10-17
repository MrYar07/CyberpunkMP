namespace CampaignSystem
{
    public class Plugin
    {
        public static Plugin Instance { get; set; }
        internal CampaignSession Session { get; private set; }

        static Plugin()
        {
            Instance = new Plugin();
        }

        Plugin()
        {
            Session = new CampaignSession();
        }
    }
}
