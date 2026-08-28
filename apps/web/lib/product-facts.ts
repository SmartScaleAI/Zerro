/**
 * The public product facts every surface quotes: price, trial, and license
 * terms. One source so the pricing section, FAQ, legal pages, and JSON-LD can
 * never disagree. Static assets (public/llms*.txt) can't import this, so
 * lib/product-copy.test.ts pins them to the same values.
 */

/** The one-time price of a Zerro license, in USD. */
export const LICENSE_PRICE_USD = 39;
/** The price as shown in copy. */
export const LICENSE_PRICE = `$${LICENSE_PRICE_USD}`;
/** Length of the free trial that every official build starts with. */
export const TRIAL_DAYS = 14;
/** How many Macs one license activates at the same time. */
export const LICENSE_MAC_COUNT = 2;
/** The major version a license covers, and the release range as written. */
export const LICENSED_MAJOR = 1;
export const LICENSED_RELEASES = `${LICENSED_MAJOR}.x.x`;
/** The next major release, which may be sold separately. */
export const NEXT_MAJOR = `${LICENSED_MAJOR + 1}.0`;
/** The license the source code is released under. */
export const SOURCE_LICENSE = "GPL-3.0-or-later";
