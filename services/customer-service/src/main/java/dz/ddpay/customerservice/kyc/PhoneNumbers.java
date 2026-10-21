package dz.ddpay.customerservice.kyc;

import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Converts phone numbers as typed in Algeria into the international format the database requires.
 *   0555 12 34 56   -> +213555123456
 *   00213555123456  -> +213555123456
 *   213555123456    -> +213555123456
 *   +33612345678    -> +33612345678   (diaspora numbers kept as they are)
 * Returns empty if the result still isn't a valid international number.
 */
public final class PhoneNumbers {

    private static final Pattern INTERNATIONAL = Pattern.compile("^\\+[1-9][0-9]{7,14}$");

    private PhoneNumbers() {}

    public static Optional<String> normalize(String raw) {
        if (raw == null) return Optional.empty();
        String p = raw.replaceAll("[\\s.\\-()]", "");
        if (p.isEmpty()) return Optional.empty();

        if (p.startsWith("00")) {
            p = "+" + p.substring(2);
        } else if (p.startsWith("0") && p.length() == 10) {
            p = "+213" + p.substring(1);          // Algerian national format: 0 + 9 digits
        } else if (p.startsWith("213") && p.length() == 12) {
            p = "+" + p;
        }

        return INTERNATIONAL.matcher(p).matches() ? Optional.of(p) : Optional.empty();
    }
}
