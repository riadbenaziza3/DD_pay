package dz.ddpay.customerservice.kyc;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class PhoneNumbersTest {

    @Test
    void algerianNationalFormatBecomesInternational() {
        assertThat(PhoneNumbers.normalize("0555123456")).contains("+213555123456");
        assertThat(PhoneNumbers.normalize("0555 12 34 56")).contains("+213555123456");
        assertThat(PhoneNumbers.normalize("0555-12-34-56")).contains("+213555123456");
    }

    @Test
    void internationalPrefixesAreUnified() {
        assertThat(PhoneNumbers.normalize("00213555123456")).contains("+213555123456");
        assertThat(PhoneNumbers.normalize("213555123456")).contains("+213555123456");
        assertThat(PhoneNumbers.normalize("+213555123456")).contains("+213555123456");
    }

    @Test
    void foreignNumbersAreKept() {
        assertThat(PhoneNumbers.normalize("+33612345678")).contains("+33612345678");
        assertThat(PhoneNumbers.normalize("0033612345678")).contains("+33612345678");
    }

    @Test
    void invalidOrMissingNumbersAreRejected() {
        assertThat(PhoneNumbers.normalize(null)).isEmpty();
        assertThat(PhoneNumbers.normalize("   ")).isEmpty();
        assertThat(PhoneNumbers.normalize("12345")).isEmpty();
        assertThat(PhoneNumbers.normalize("abc")).isEmpty();
    }
}
