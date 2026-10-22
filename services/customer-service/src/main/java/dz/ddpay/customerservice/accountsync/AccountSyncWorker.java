package dz.ddpay.customerservice.accountsync;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Background job that applies queued account syncs.
 *
 * For each row it reads the customer's CURRENT state and makes account-service match it:
 *   may transact     -> open the account if needed, unfreeze it if frozen
 *   may not transact -> freeze the account if it exists (never open one)
 */
@Component
public class AccountSyncWorker {

    private static final Logger log = LoggerFactory.getLogger(AccountSyncWorker.class);
    private static final int BATCH_SIZE = 20;

    private final AccountSyncStore store;
    private final AccountClient accounts;
    private boolean warnedNotConfigured;

    public AccountSyncWorker(AccountSyncStore store, AccountClient accounts) {
        this.store = store;
        this.accounts = accounts;
    }

    @Scheduled(fixedDelayString = "${account-sync.poll-delay-ms:2000}", initialDelayString = "${account-sync.initial-delay-ms:10000}")
    public void processDue() {
        if (!accounts.isConfigured()) {
            if (!warnedNotConfigured) {
                log.warn("Account sync is OFF: account-sync.client-secret is not set (ACCOUNT_SYNC_CLIENT_SECRET)");
                warnedNotConfigured = true;
            }
            return;
        }

        List<AccountSyncStore.Claimed> rows = store.claimDue(BATCH_SIZE);
        for (AccountSyncStore.Claimed row : rows) {
            process(row);
        }
    }

    /** Safety net, e.g. ID documents that expire today produce no event: find and queue them. */
    @Scheduled(fixedDelayString = "${account-sync.reconcile-delay-ms:300000}", initialDelayString = "${account-sync.reconcile-initial-delay-ms:30000}")
    public void reconcile() {
        int queued = store.enqueueDrift();
        if (queued > 0) {
            log.info("Account sync reconciliation queued {} customer(s)", queued);
        }
    }

    private void process(AccountSyncStore.Claimed row) {
        try {
            Optional<AccountSyncStore.CustomerState> customer = store.loadCustomer(row.customerId());
            if (customer.isEmpty()) {
                store.markFailed(row, "customer " + row.customerId() + " not found");
                return;
            }
            AccountSyncStore.CustomerState c = customer.get();
            Result result = apply(c);
            store.markDone(row, result.state(), result.reason());
            log.info("Account sync #{}: customer {} -> account {} ({})",
                row.id(), c.id(), result.state(), result.reason());

        } catch (AccountClient.PermanentFailure e) {
            log.error("Account sync #{} for customer {} refused, not retrying: {}",
                row.id(), row.customerId(), e.getMessage());
            store.markFailed(row, e.getMessage());

        } catch (Exception e) {
            log.warn("Account sync #{} for customer {} failed (attempt {}), will retry: {}",
                row.id(), row.customerId(), row.attempts(), e.toString());
            store.markRetry(row, e.toString());
        }
    }

    private record Result(String state, String reason) {}

    private Result apply(AccountSyncStore.CustomerState c) {
        if (c.canTransact()) {
            Map<?, ?> account = accounts.open(c.id());
            String status = String.valueOf(account.get("status"));
            if ("active".equals(status)) {
                return new Result("active", "KYC verified, AML clear");
            }
            if ("closed".equals(status)) {
                return new Result("closed", "account is closed");
            }
            accounts.setStatus(c.id(), "active", "KYC verified, AML clear");
            return new Result("active", "unfrozen: KYC verified, AML clear");
        }

        Optional<Map<?, ?>> existing = accounts.find(c.id());
        if (existing.isEmpty()) {
            return new Result("none", "no account, " + c.freezeReason());
        }
        String status = String.valueOf(existing.get().get("status"));
        if ("closed".equals(status)) {
            return new Result("closed", "account is closed");
        }
        String reason = c.freezeReason();
        if (!"frozen".equals(status)) {
            accounts.setStatus(c.id(), "frozen", reason);
        }
        return new Result("frozen", reason);
    }
}
