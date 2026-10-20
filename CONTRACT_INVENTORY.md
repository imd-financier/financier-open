# Solidity inventory

All project sources retain exact reviewed bytes. Interfaces are dependencies. Historical modules remain for regression reproduction and are not deployment instructions.

| Source | Role | SHA-256 |
|---|---|---|
| src/AgentRounds.sol | historical / deferred; not a production deployment | 75ab9e518b15cbfdd13f17d2a842aa4d1d5133689c2d980245a60d6eaab1b09a |
| src/AttestedAgentRounds.sol | production candidate / inherited dependency | 979b685b3b1c959e61f01a149c43e4d5e96717d6d023fd41232c4060cd541ba2 |
| src/EmissionSchedule.sol | production candidate / inherited dependency | dd9fc7cd811f0d4f61a2af1a29e5d36e38018248e72832a277bbb8743adfdd6e |
| src/FINCR.sol | production candidate / inherited dependency | 893149e5145b06a2c45b8d6f43a3a91bf1ff7312bca1cc60fd80259cd78cc0e1 |
| src/FinancierFeeRouter.sol | historical / deferred; not a production deployment | e08c671bb7f9f8d7be106df52b2bce50dc357039f22c5464df077da2bbc6e6a3 |
| src/FinancierMining.sol | production candidate / inherited dependency | 4f1eff1ab24355d5074f21235f586923ccc09b4ef9b25f6cd4825c2762800c34 |
| src/FinancierMiningWithAgents.sol | historical / deferred; not a production deployment | 7b2ce533df0bb33275622740ca7881b58065f2c96f15aff0abb3668e02808cb0 |
| src/FinancierMiningWithMarket.sol | production candidate / inherited dependency | 691678e300b1fdf3037aeeac1dc0b83d0bcf24d8db9df6710c8c0e90de53cee3 |
| src/FinancierMiningWithSettlement.sol | production candidate / inherited dependency | 09df4f403a30dca09559459bf08150819b91f873995e49299514ca994aba211d |
| src/FounderFundedMining.sol | production candidate / inherited dependency | 2f186e97b40f49132ca422f46652521dbae988c7c00c9c954269d4bfdb030b3b |
| src/PublisherGateway.sol | production candidate / inherited dependency | b1713323f3a127b99dd34f1dc7ce7bf7edf38fd592eeb746537eb1556cd6aa44 |
| src/ReserveForwarder.sol | historical / deferred; not a production deployment | ffdc4591c116a612f660c92877b77f600ced5895b86699406a3ec3a071200d09 |
| src/RestrictedMarketReserveReceiver.sol | historical / deferred; not a production deployment | f9bc2ec7d7c9d8e6c01e6b3d04cae8b859978e1a312da4dc55cb18ec1369409d |
| src/RestrictedReserveReceiver.sol | historical / deferred; not a production deployment | dbd8998681382ab2f9fbb411bda71d04f6b87babdf483ace621846cbe2eef62c |
| src/RobinhoodJobController.sol | production candidate / inherited dependency | 36b13048389f89c60662452f2f5159bbb1f7ea60e1c14b3c8357dc4becb0add8 |
| src/SeatOwnerAgentRounds.sol | production candidate / inherited dependency | 9aa09fcfba46d15a0913b69ff5596233bc7370e1e3646dee4371b0993edd14d5 |
| src/UnavailableWorkVerifier.sol | historical / deferred; not a production deployment | c85467810291d0da19b2e87eb22a2dc0999013a8373a5ac53fe46653d376518a |
| src/interfaces/IAgentWorkVerifier.sol | interface dependency | 56d81f9286799b18dbe763fa8f16911510f808924f5b68d6159f597015534268 |
| src/interfaces/IIMDIntake.sol | interface dependency | eabd9124203bcec4c9bff1726cea1c913c6e9ba106a3beda9b48310384fe727b |
| src/interfaces/IIMDIntakeViews.sol | interface dependency | 86a4ad3fadf7c02dea441b039d07ef270e22c0c768ff55b0a63ee7c4295038b3 |
| src/interfaces/IIMDLaunch.sol | interface dependency | db15fbdc01e2716b50b03913c4893f6a3d20c34a4562e0ae8e2e09efbe7ff8ca |
| src/market/IV4Market.sol | interface dependency | 95f1473081f2490e0074b31cb8108dd53f3c9904ba6b29ad9069b8a72a7cd731 |
| src/market/PermanentV4Market.sol | production candidate / inherited dependency | 89a334d7cda49eaa83d085db6dbd6ac873f1d3dcc14173ed6c2ea2aee7346d7c |
