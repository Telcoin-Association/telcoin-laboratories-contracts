# TELx Liquidity Mining: Essential Guide for LPs

**Welcome to the new TELx incentive program on Uniswap v4.**
To ensure fair distribution and a secure ecosystem, this program uses specific rules to calculate rewards. Please read this carefully to ensure your position remains eligible for TEL rewards.

## 🚨 The Golden Rule: Patience Pays (Current Configuration)
The goal of this program is to reward **long-term, stable liquidity**. We categorize your behavior into three types. **Currently, only "Passive" behavior is rewarded.**

> **Note:** These weights (0% vs 100%) and the time thresholds (24 hours) are set by the TELx Council. They can be changed at any time to adapt to market conditions, though we expect the current configuration to remain stable.

### 1. Passive Liquidity (✅ Rewarded)
* **Definition:** You add liquidity and **leave it untouched for at least 24 hours**.
* **Reward Weight:** **100%**. You receive full rewards for the duration your liquidity is provided.

### 2. Active Liquidity (❌ NO Rewards)
* **Definition:** You modify your position (add or remove liquidity) more frequently than once every 24 hours.
* **Reward Weight:** **0%**.
* **The Consequence:** If you modify your position, and then modify it again within 24 hours, the system classifies your behavior as "Active" for that period. **You will earn 0 TEL rewards for that period.**

### 3. Just-In-Time (JIT) Liquidity (❌ NO Rewards)
* **Definition:** Adding and removing liquidity within the exact same block or very short timeframe.
* **Reward Weight:** **0%**.

---

## ⚠️ Minimum Position Size (The 1 Basis Point Rule)
To protect the system from Denial-of-Service (DoS) attacks where malicious actors spam the registry with dust positions, we enforce a strict minimum size.

* **The Threshold:** Your position must represent at least **0.01% (1 basis point)** of the pool's total liquidity.
* **When is this checked?** The system checks this **every time you modify your position** (whether you add OR remove liquidity).
* **The Consequence:** If your modification results in a position size below 0.01%, **you are automatically unsubscribed.** This can happen if:
    1.  You withdraw too much liquidity, dropping below the limit.
    2.  The pool has grown significantly (diluting your share), and you submit a modification while under the threshold.
* **The Fix:** If you are unsubscribed, you must add enough liquidity to get back above 0.01% and manually hit "Subscribe" again.

---

## How to Participate (Step-by-Step)

1.  **Create Position:** Provide liquidity to a supported TELx pool on Uniswap v4.
2.  **Subscribe (Required):** You must explicitly click **"Subscribe"** on the TELx interface. Simply holding the NFT is not enough; you must opt-in.
3.  **Stay Passive:** Avoid modifying your position more than once a day.
4.  **Monitor Ownership:** If you transfer your NFT to a new wallet or sell it, the position is automatically unsubscribed. The new owner must re-subscribe.
5.  **Vote:** Your subscribed liquidity gives you voting power in TELx Governance.

## FAQ: Why did I get 0 rewards?

* **Did you modify your position twice in one day?**
    * *Yes:* You were classified as "Active" (Weight = 0). Please wait at least 24 hours between adjustments.
* **Is your position very small?**
    * *Yes:* You may have dropped below the 0.01% threshold and been unsubscribed during your last modification. Check your status in the UI.
* **Did you forget to Subscribe?**
    * *Yes:* Rewards only start accumulating *after* you send the Subscribe transaction.
* **Did you just transfer the NFT?**
    * *Yes:* Transfers reset the subscription status. You must re-subscribe the new wallet.
